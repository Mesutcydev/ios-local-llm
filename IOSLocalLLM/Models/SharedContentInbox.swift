import Foundation

/// File-based hand-off shared by the app and its Share extension. Share
/// extensions save content; they do not use UIApplication to launch the app.
enum SharedContentInbox {
    static let directoryName = "PendingShares"
    private static let maximumBytes = 32 * 1024
    private static let maximumAge: TimeInterval = 24 * 60 * 60

    private struct Entry: Codable {
        let createdAt: Date
        let url: URL
    }

    static func handOffURL(queryName: String, value: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "ios-local-llm"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: queryName, value: value)]
        guard let url = components.url else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
        return url
    }

    @discardableResult
    static func save(_ url: URL, in container: URL, now: Date = .now) throws -> URL {
        guard isShareURL(url) else { throw CocoaError(.fileWriteInvalidFileName) }
        let data = try JSONEncoder().encode(Entry(createdAt: now, url: url))
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("share-\(UUID().uuidString).json")
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return destination
    }

    /// Consume one item per foreground visit so additional shares cannot
    /// overwrite a composer the user is already editing. Invalid/expired
    /// envelopes are discarded without opening their URL.
    static func takeNext(in container: URL, now: Date = .now) -> URL? {
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var entries: [(URL, Entry)] = []
        for file in files where file.pathExtension == "json" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let data = try? handle.read(upToCount: maximumBytes + 1)
            try? handle.close()
            guard let data, data.count <= maximumBytes,
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  isShareURL(entry.url),
                  now.timeIntervalSince(entry.createdAt) < maximumAge else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            entries.append((file, entry))
        }
        guard let next = entries.min(by: { $0.1.createdAt < $1.1.createdAt }) else { return nil }
        // Do not claim a single-use share if its envelope could not be removed.
        do { try FileManager.default.removeItem(at: next.0) }
        catch { return nil }
        return next.1.url
    }

    static func isShareURL(_ url: URL) -> Bool {
        ["ios-local-llm", "codelens"].contains(url.scheme?.lowercased() ?? "")
            && url.host == "share"
    }
}
