import Foundation
import CloudKit
import Combine

// MARK: - CloudSyncService
// Best-effort iCloud sync for conversation history using the user's private
// CloudKit database. Off by default — user opts in via Settings.
//
// Records:
//   • Type: "Conversation"
//   • Fields: id (string), title (string), createdAt (date), updatedAt (date),
//             jsonBlob (string)   ← entire StoredConversation encoded as JSON
//
// On sync: pull all records, merge by updatedAt (last-write-wins), then push
// local changes. Tiny payload so even slow connections finish quickly.

@MainActor
final class CloudSyncService: ObservableObject {

    static let shared = CloudSyncService()

    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    private lazy var container = CKContainer(identifier: "iCloud.com.mesutcydev.ioslocalllm")
    private var privateDB: CKDatabase { container.privateCloudDatabase }

    private let availability: (() async -> Bool)?
    private let synchronize: (() async throws -> Void)?
    private let isEnabled: () -> Bool

    init(availability: (() async -> Bool)? = nil,
         synchronize: (() async throws -> Void)? = nil,
         isEnabled: @escaping () -> Bool = { AppSettings.shared.iCloudSyncEnabled }) {
        self.availability = availability
        self.synchronize = synchronize
        self.isEnabled = isEnabled
    }

    // MARK: - Availability

    /// True when the user is signed into iCloud AND has the app's container access.
    func iCloudAvailable() async -> Bool {
        let status = try? await container.accountStatus()
        return status == .available
    }

    // MARK: - Sync

    /// Full bidirectional sync. Safe to call repeatedly.
    func syncNow() async {
        guard !isSyncing, isEnabled() else { return }
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        let available: Bool
        if let availability { available = await availability() }
        else { available = await iCloudAvailable() }
        guard isEnabled(), !Task.isCancelled else { return }
        guard available else {
            lastError = "iCloud not available — sign in via Settings."
            return
        }
        do {
            if let synchronize { try await synchronize() }
            else { try await pullThenPush() }
            try checkEnabled()
            lastSyncAt = .now
            ToastCenter.shared.success("iCloud sync complete")
        } catch is CancellationError {
            // Disabling sync is a user choice, not a service failure.
        } catch {
            lastError = error.localizedDescription
            ToastCenter.shared.error("iCloud sync failed", detail: error.localizedDescription)
        }
    }

    private func checkEnabled() throws {
        try Task.checkCancellation()
        guard isEnabled() else { throw CancellationError() }
    }

    /// Fetch all pages before applying any local merge or remote writes.
    static func collectPages<Item, Cursor>(
        fetch: (Cursor?) async throws -> ([Item], Cursor?)
    ) async throws -> [Item] {
        var cursor: Cursor?
        var items: [Item] = []
        repeat {
            try Task.checkCancellation()
            let page = try await fetch(cursor)
            items.append(contentsOf: page.0)
            cursor = page.1
        } while cursor != nil
        return items
    }

    // MARK: - Internals

    private func pullThenPush() async throws {
        // Keep deletion markers until reconciliation. Age alone cannot prove
        // every device has synced and pruning can resurrect deleted history.

        let query = CKQuery(recordType: "Conversation",
                            predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        let records: [CKRecord] = try await Self.collectPages { (cursor: CKQueryOperation.Cursor?) in
            try self.checkEnabled()
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
            if let cursor {
                page = try await self.privateDB.records(continuingMatchFrom: cursor, resultsLimit: 500)
            } else {
                page = try await self.privateDB.records(matching: query, resultsLimit: 500)
            }
            // A missing/failed record must not be mistaken for an absent
            // conversation and overwritten during push.
            return (try page.matchResults.map { try $0.1.get() }, page.queryCursor)
        }
        try checkEnabled()
        var remoteByID: [String: (record: CKRecord, conv: StoredConversation)] = [:]
        for record in records {
            guard let blob = record["jsonBlob"] as? String,
                  let data = blob.data(using: .utf8),
                  let conv = try? JSONDecoder.iso8601.decode(StoredConversation.self, from: data) else {
                throw CloudSyncError.invalidRemotePayload
            }
            remoteByID[conv.id.uuidString] = (record, conv)
        }

        // Finish network deletions before snapshotting local state: the user
        // may edit or delete conversations while CloudKit is suspended.
        let store = ConversationStore.shared
        var deleteFailures = 0
        for (id, remote) in remoteByID {
            try checkEnabled()
            // Deletion propagation: if we deleted this conversation locally and
            // NO device has edited it since (remote.updatedAt <= the deletion
            // time), honour the delete — remove it from CloudKit and DON'T
            // resurrect it into the local set. Without this, every sync pulled
            // the still-present remote record straight back (the "deleted chats
            // come back" bug). A remote edit newer than our tombstone wins
            // under last-write-wins, so a genuine re-edit elsewhere still
            // revives the conversation.
            if let deletedAt = CloudSyncTombstones.deletionDate(id),
               remote.conv.updatedAt <= deletedAt {
                do {
                    _ = try await privateDB.deleteRecord(withID: remote.record.recordID)
                } catch {
                    deleteFailures += 1
                    Diagnostics.shared.warning(
                        "cloud tombstone delete failed",
                        category: "cloudSync"
                    )
                }
                continue
            }
        }
        try checkEnabled()
        var localByID = Dictionary(uniqueKeysWithValues:
            store.conversations.map { ($0.id.uuidString, $0) })
        for (id, remote) in remoteByID {
            if let deletedAt = CloudSyncTombstones.deletionDate(id), remote.conv.updatedAt <= deletedAt {
                continue
            }
            // Remote is live (or was re-edited after our delete) — clear any
            // stale tombstone so it can sync normally again, then merge.
            CloudSyncTombstones.clear(id)
            if let local = localByID[id] {
                if remote.conv.updatedAt > local.updatedAt {
                    localByID[id] = remote.conv
                }
            } else {
                localByID[id] = remote.conv
            }
        }

        // Apply merged set back to local store
        try checkEnabled()
        store.replaceAll(with: Array(localByID.values))

        // Push: every local conversation that's newer than (or missing from) remote
        var pushFailures = 0
        let pushTotal = localByID.count
        for snapshot in localByID.values {
            try checkEnabled()
            // Use the current local version after each preceding network wait.
            guard let conv = store.conversations.first(where: { $0.id == snapshot.id }) else { continue }
            let recordID = CKRecord.ID(recordName: conv.id.uuidString)
            let existing = remoteByID[conv.id.uuidString]?.record
            if let existing, let rUpdated = existing["updatedAt"] as? Date,
               rUpdated >= conv.updatedAt { continue }

            let record = existing ?? CKRecord(recordType: "Conversation", recordID: recordID)
            record["title"] = conv.title as CKRecordValue
            record["createdAt"] = conv.createdAt as CKRecordValue
            record["updatedAt"] = conv.updatedAt as CKRecordValue
            do {
                let data = try JSONEncoder.iso8601.encode(conv)
                guard let blob = String(data: data, encoding: .utf8) else {
                    throw CloudSyncError.invalidEncodedPayload
                }
                record["jsonBlob"] = blob as CKRecordValue
            } catch {
                pushFailures += 1
                Diagnostics.shared.error(
                    "cloud payload encode failed",
                    category: "cloudSync"
                )
                continue
            }
            do {
                _ = try await privateDB.save(record)
            } catch {
                pushFailures += 1
                Diagnostics.shared.error(
                    "cloud push failed",
                    category: "cloudSync"
                )
            }
        }
        if deleteFailures > 0 { throw CloudSyncError.partialDelete(failed: deleteFailures) }
        if pushFailures > 0 {
            throw CloudSyncError.partialPush(failed: pushFailures, total: pushTotal)
        }
    }
}

// MARK: - Errors

enum CloudSyncError: LocalizedError {
    case partialPush(failed: Int, total: Int)
    case invalidEncodedPayload
    case invalidRemotePayload
    case partialDelete(failed: Int)

    var errorDescription: String? {
        switch self {
        case .partialPush(let failed, let total):
            return "iCloud sync incomplete — \(failed) of \(total) conversations failed to upload."
        case .partialDelete(let failed):
            return "iCloud sync incomplete — \(failed) deletions could not be uploaded. Retry sync."
        case .invalidRemotePayload:
            return "iCloud contains an unreadable conversation. No conversations were merged or uploaded."
        case .invalidEncodedPayload:
            return "Conversation payload couldn't be encoded as UTF-8."
        }
    }
}

// MARK: - JSON helpers

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

// MARK: - Deletion tombstones

/// Records conversations the user deleted locally so the next iCloud sync can
/// propagate the deletion to CloudKit instead of pulling the still-present
/// remote record back (sync "resurrection"). Backed by UserDefaults (a tiny
/// `[idString: epochSeconds]` map) — thread-safe and cheap, so the
/// non-`@MainActor` `ConversationStore` can stamp deletions inline.
enum CloudSyncTombstones {
    private static let key = "cloudSync.deletedConversationIDs"

    private static func all() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }

    /// Stamp a conversation as deleted at the current time.
    static func mark(_ id: UUID) {
        var t = all()
        t[id.uuidString] = Date().timeIntervalSince1970
        UserDefaults.standard.set(t, forKey: key)
    }

    /// Forget a tombstone (e.g. a newer remote edit legitimately revived it).
    static func clear(_ idString: String) {
        var t = all()
        guard t.removeValue(forKey: idString) != nil else { return }
        UserDefaults.standard.set(t, forKey: key)
    }

    static func deletionDate(_ idString: String) -> Date? {
        all()[idString].map { Date(timeIntervalSince1970: $0) }
    }

    /// Drop tombstones older than `days` so the set can't grow unbounded.
    static func pruneOlderThan(days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let t = all()
        let kept = t.filter { $0.value >= cutoff }
        if kept.count != t.count {
            UserDefaults.standard.set(kept, forKey: key)
        }
    }
}
