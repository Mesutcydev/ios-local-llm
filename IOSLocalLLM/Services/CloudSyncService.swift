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

    private let container = CKContainer(identifier: "iCloud.com.mesutcydev.ioslocalllm")
    private var privateDB: CKDatabase { container.privateCloudDatabase }

    private init() {}

    // MARK: - Availability

    /// True when the user is signed into iCloud AND has the app's container access.
    func iCloudAvailable() async -> Bool {
        let status = try? await container.accountStatus()
        return status == .available
    }

    // MARK: - Sync

    /// Full bidirectional sync. Safe to call repeatedly.
    func syncNow() async {
        guard !isSyncing else { return }
        guard AppSettings.shared.iCloudSyncEnabled else { return }
        guard await iCloudAvailable() else {
            lastError = "iCloud not available — sign in via Settings."
            return
        }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await pullThenPush()
            lastSyncAt = .now
            ToastCenter.shared.success("iCloud sync complete")
        } catch {
            lastError = error.localizedDescription
            ToastCenter.shared.error("iCloud sync failed",
                                      detail: error.localizedDescription)
        }
    }

    // MARK: - Internals

    private func pullThenPush() async throws {
        // Drop tombstones old enough that every device has certainly synced
        // past them, so the deleted-ID set can't grow without bound.
        CloudSyncTombstones.pruneOlderThan(days: 90)

        let query = CKQuery(recordType: "Conversation",
                            predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        // Pull
        let (matchResults, _) = try await privateDB.records(matching: query, resultsLimit: 500)
        var remoteByID: [String: (record: CKRecord, conv: StoredConversation)] = [:]
        for (_, result) in matchResults {
            switch result {
            case .success(let record):
                guard let blob = record["jsonBlob"] as? String,
                      let data = blob.data(using: .utf8) else {
                    Diagnostics.shared.warning(
                        "cloud record \(record.recordID.recordName) has no valid JSON payload",
                        category: "cloudSync"
                    )
                    continue
                }
                do {
                    let conv = try JSONDecoder.iso8601.decode(
                        StoredConversation.self,
                        from: data
                    )
                    remoteByID[conv.id.uuidString] = (record, conv)
                } catch {
                    Diagnostics.shared.warning(
                        "cloud record \(record.recordID.recordName) decode failed: \(error.localizedDescription)",
                        category: "cloudSync"
                    )
                }
            case .failure(let error):
                Diagnostics.shared.warning(
                    "cloud record fetch failed: \(error.localizedDescription)",
                    category: "cloudSync"
                )
            }
        }

        // Merge into local — last write wins by updatedAt
        let store = ConversationStore.shared
        var localByID = Dictionary(uniqueKeysWithValues:
            store.conversations.map { ($0.id.uuidString, $0) })

        for (id, remote) in remoteByID {
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
                    Diagnostics.shared.warning(
                        "cloud tombstone delete failed for \(id): \(error.localizedDescription)",
                        category: "cloudSync"
                    )
                }
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
        store.replaceAll(with: Array(localByID.values))

        // Push: every local conversation that's newer than (or missing from) remote
        var pushFailures = 0
        let pushTotal = localByID.count
        for conv in localByID.values {
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
                    "cloud payload encode failed for \(conv.id.uuidString): \(error.localizedDescription)",
                    category: "cloudSync"
                )
                continue
            }
            do {
                _ = try await privateDB.save(record)
            } catch {
                pushFailures += 1
                Diagnostics.shared.error(
                    "cloud push failed for \(conv.id.uuidString): \(error.localizedDescription)",
                    category: "cloudSync"
                )
            }
        }
        if pushFailures > 0 {
            throw CloudSyncError.partialPush(failed: pushFailures, total: pushTotal)
        }
    }
}

// MARK: - Errors

enum CloudSyncError: LocalizedError {
    case partialPush(failed: Int, total: Int)
    case invalidEncodedPayload

    var errorDescription: String? {
        switch self {
        case .partialPush(let failed, let total):
            return "iCloud sync incomplete — \(failed) of \(total) conversations failed to upload."
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
