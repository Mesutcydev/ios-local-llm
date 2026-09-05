import Foundation

/// Shared Hugging Face tree-API helpers used by both the generic downloader
/// and the Core AI pack downloader so checksums and pagination stay in sync.
enum HFHubMetadata {
    /// Hugging Face tree `lfs.oid` is typically `sha256:<64 hex>`. Compare
    /// against CryptoKit hex, not the prefixed form.
    static func normalizedSHA256(_ oid: String) -> String? {
        let value = oid.hasPrefix("sha256:")
            ? String(oid.dropFirst("sha256:".count))
            : oid
        let lower = value.lowercased()
        guard lower.count == 64,
              lower.allSatisfy(\.isHexDigit) else { return nil }
        return lower
    }

    /// Extracts the `cursor` query parameter from an RFC `Link: <…>; rel="next"` header.
    static func nextCursor(fromLinkHeader header: String?) -> String? {
        guard let header else { return nil }
        for segment in header.split(separator: ",") {
            let parts = segment.split(separator: ";")
            guard let target = parts.first,
                  parts.dropFirst().contains(where: {
                      $0.trimmingCharacters(in: .whitespaces)
                          .hasPrefix("rel=\"next\"")
                  }) else { continue }
            let trimmed = target.trimmingCharacters(
                in: CharacterSet(charactersIn: " <>")
            )
            guard let url = URL(string: trimmed),
                  let components = URLComponents(
                      url: url,
                      resolvingAgainstBaseURL: false
                  ) else { continue }
            return components.queryItems?
                .first { $0.name == "cursor" }?
                .value
        }
        return nil
    }
}

/// GGUF mmap admission: zero available bytes means no headroom, not "unknown."
enum GGUFLoadAdmission {
    static func shouldAdmit(fileBytes: Int64, available: Int64, minimumNeeded: Int64) -> Bool {
        if fileBytes > 0, available <= 0 { return false }
        return available >= minimumNeeded
    }
}
