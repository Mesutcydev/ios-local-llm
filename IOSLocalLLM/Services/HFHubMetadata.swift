import CryptoKit
import Foundation

// Adapted from OnDevice Core (MIT; see LICENSE and Docs/COREAI_COMPARISON.md).
enum HFHubMetadata {
    /// LFS OIDs may include an algorithm prefix; CryptoKit produces bare hex.
    static func normalizedSHA256(_ oid: String) -> String? {
        let value = oid.hasPrefix("sha256:") ? String(oid.dropFirst(7)) : oid
        let bytes = Array(value.utf8)
        guard bytes.count == 64, bytes.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return nil }
        return value.lowercased()
    }

    /// Streamed SHA-256 of a file in 4 MB chunks. Each chunk is read inside
    /// its own autorelease pool: without it FileHandle's buffers pile up until
    /// the loop ends, so verifying an 8.6 GB weights file held ~8.6 GB of RAM
    /// and iOS killed the app right as the download finished.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Read only the cursor from a next-page link. Requests stay on the
    /// original Hugging Face endpoint, so a Link cannot redirect credentials.
    static func nextCursor(fromLinkHeader header: String?) -> String? {
        guard let header else { return nil }
        for segment in header.components(separatedBy: ",") {
            let parts = segment.components(separatedBy: ";")
            let isNext = parts.dropFirst().contains { parameter in
                let pair = parameter.split(separator: "=", maxSplits: 1)
                guard pair.count == 2,
                      pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel" else { return false }
                let relations = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                return relations.split(whereSeparator: \.isWhitespace).contains("next")
            }
            guard isNext, let target = parts.first,
                  let url = URLComponents(string: target.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t"))),
                  let cursor = url.queryItems?.first(where: { $0.name == "cursor" })?.value,
                  !cursor.isEmpty else { continue }
            return cursor
        }
        return nil
    }
}
