import Foundation

// MARK: - WebActivityLogger
// User-visible log of every outbound web request and every redaction. Stored
// on-device only. Rotated at 500 entries / 1 MB whichever comes first. API
// keys and response bodies are NEVER written here.

@MainActor
public final class WebActivityLogger: ObservableObject {

    public static let shared = WebActivityLogger()

    @Published public private(set) var entries: [WebActivityLogEntry] = []

    private let maxEntries = 500
    private let storageKey = "ioslocalllm.webtool.activity.v1"

    private init() { load() }

    public func record(_ entry: WebActivityLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        save()
    }

    public func clear() {
        entries = []
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Stored].self, from: data)
        else { return }
        entries = decoded.map { $0.entry }
    }

    private func save() {
        let stored = entries.prefix(maxEntries).map(Stored.init)
        guard let data = try? JSONEncoder().encode(Array(stored)) else { return }
        // Soft-cap on byte size: drop oldest until under 1 MB.
        if data.count > 1_000_000 {
            entries = Array(entries.prefix(entries.count / 2))
            save()
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// `WebActivityLogEntry` carries an `Error`-shaped enum field which we
    /// don't actually persist — we serialize a simplified shape instead.
    private struct Stored: Codable {
        var id: UUID
        var ts: Date
        var kindRaw: String
        var providerRaw: String?
        var queryOrURL: String
        var statusCode: Int?
        var bytesIn: Int?
        var durationMs: Int?
        var fromCache: Bool
        var note: String?

        init(_ e: WebActivityLogEntry) {
            self.id = e.id
            self.ts = e.timestamp
            self.kindRaw = e.kind.rawValue
            self.providerRaw = e.provider?.rawValue
            self.queryOrURL = e.queryOrURL
            self.statusCode = e.statusCode
            self.bytesIn = e.bytesIn
            self.durationMs = e.durationMs
            self.fromCache = e.fromCache
            self.note = e.note
        }

        var entry: WebActivityLogEntry {
            WebActivityLogEntry(
                id: id, timestamp: ts,
                kind: WebActivityLogEntry.Kind(rawValue: kindRaw) ?? .error,
                provider: providerRaw.flatMap { WebSearchProvider(rawValue: $0) },
                queryOrURL: queryOrURL,
                statusCode: statusCode, bytesIn: bytesIn,
                durationMs: durationMs, fromCache: fromCache, note: note
            )
        }
    }
}
