import Foundation
import Combine

// MARK: - HFSearchService
// Queries the public Hugging Face Hub search API for models.
//
// Endpoint: https://huggingface.co/api/models?search=<q>&filter=<f>&limit=N&full=true
// No authentication required for public models.
//
// We restrict by default to MLX / Core ML / GGUF–compatible repos that have
// some chance of running on-device. This is a heuristic filter, not a guarantee.

@MainActor
final class HFSearchService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var results: [HFModelSummary] = []
    @Published private(set) var isSearching = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastQuery: String = ""

    private var activeSearchID = UUID()
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)

    init(fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }) {
        self.fetch = fetch
    }

    // MARK: - Filter options

    enum Filter: String, CaseIterable, Identifiable {
        case all       = "All"
        case mlx       = "MLX"
        case coreml    = "Core ML"
        case textGen   = "Text Generation"
        case vlm       = "Vision–Language"
        case tts       = "Text-to-Speech"
        case asr       = "Speech-to-Text"

        var id: String { rawValue }

        /// HF library/tag filter applied to the search.
        /// Multiple filters can be passed as repeated &filter=… parameters.
        var hfFilters: [String] {
            switch self {
            case .all:     return []
            case .mlx:     return ["mlx"]
            case .coreml:  return ["coreml"]
            case .textGen: return ["text-generation"]
            case .vlm:     return ["image-text-to-text"]
            case .tts:     return ["text-to-speech"]
            case .asr:     return ["automatic-speech-recognition"]
            }
        }
    }

    // MARK: - Search

    func search(query: String, filter: Filter = .all, limit: Int = 30) async {
        let searchID = UUID()
        activeSearchID = searchID
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        lastQuery = trimmed
        // Allow filter-only browsing (empty query) when the caller has picked
        // a non-.all filter — that's how the download manager's "browse visual
        // models" / "browse audio models" landing pages populate without
        // forcing the user to type a keyword first.
        if trimmed.isEmpty && filter.hfFilters.isEmpty {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        defer {
            if activeSearchID == searchID { isSearching = false }
        }

        do {
            var components = URLComponents(string: "https://huggingface.co/api/models")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "limit",  value: String(limit)),
                URLQueryItem(name: "sort",   value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(name: "full",   value: "true"),
            ]
            if !trimmed.isEmpty {
                items.append(URLQueryItem(name: "search", value: trimmed))
            }
            for f in filter.hfFilters {
                items.append(URLQueryItem(name: "filter", value: f))
            }
            components.queryItems = items
            guard let url = components.url else { throw URLError(.badURL) }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            // Attach HF token when present + enabled — lets the user
            // discover gated repos they have access to.
            HFTokenStore.authorize(&request)
            let (data, response) = try await fetch(request)
            guard activeSearchID == searchID else { return }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }

            let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            results = raw.map(HFModelSummary.init(json:))

        } catch {
            guard activeSearchID == searchID else { return }
            // Typing another query or closing search is not a network failure.
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            lastError = error.localizedDescription
            results = []
        }
    }

    // MARK: - Repo file size estimate (for cards)

    /// Cached size lookups so each scroll-into-view row doesn't fire a fresh
    /// network call. Cache lives for the process lifetime.
    private static var sizeCache: [String: Int64] = [:]

    /// Fetches an estimated total file size by listing the repo's file tree.
    /// Returns nil if the call fails or the repo is private.
    ///
    /// Robust against the same gotchas as HFModelDownloadManager:
    ///   • HF tree API uses type "file" (not "blob")
    ///   • Recursive=true to enumerate subdirectories (mlpackages, etc.)
    ///   • LFS sizes nested under "lfs.size"
    ///   • Falls back to /api/models/{repo} siblings if tree returns empty
    // `static` so HFSearchRow doesn't instantiate a throwaway @MainActor
    // ObservableObject per visible row just to read this. Stays @MainActor via
    // the class isolation, so the static `sizeCache` access remains serialized.
    static func estimatedSize(for repoID: String) async -> Int64? {
        // Fast path: process-lifetime cache. Prevents the per-row network
        // storm when the user scrolls through HF search results.
        if let cached = Self.sizeCache[repoID] { return cached }

        let urlString = "https://huggingface.co/api/models/\(repoID)/tree/main?recursive=true&expand=true"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("ios-local-llm/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        HFTokenStore.authorize(&request)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let raw = try? JSONSerialization.jsonObject(with: data)
            else { return nil }

            // Tolerate both array-of-files and {tree: [...]} shapes
            let arr: [[String: Any]]
            if let a = raw as? [[String: Any]]              { arr = a }
            else if let d = raw as? [String: Any],
                    let t = d["tree"] as? [[String: Any]]   { arr = t }
            else                                            { arr = [] }

            let total = arr.reduce(Int64(0)) { sum, item in
                // HF uses "file" / "directory" (not Git's "blob" / "tree")
                if let type_ = item["type"] as? String,
                   type_ == "directory" || type_ == "tree" { return sum }
                // size can be Int, NSNumber, or nested in lfs
                let s: Int64 = {
                    if let n = item["size"] as? NSNumber { return n.int64Value }
                    if let n = item["size"] as? Int      { return Int64(n) }
                    if let lfs = item["lfs"] as? [String: Any] {
                        if let n = lfs["size"] as? NSNumber { return n.int64Value }
                        if let n = lfs["size"] as? Int      { return Int64(n) }
                    }
                    return 0
                }()
                return sum + s
            }

            if total > 0 {
                Self.sizeCache[repoID] = total
                return total
            }
            // Fallback: siblings endpoint can have sizes when tree returns 0
            if let sib = await siblingsSize(for: repoID) {
                Self.sizeCache[repoID] = sib
                return sib
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Last-resort size estimate via /api/models/{repo} siblings list.
    private static func siblingsSize(for repoID: String) async -> Int64? {
        let urlString = "https://huggingface.co/api/models/\(repoID)"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("ios-local-llm/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        HFTokenStore.authorize(&request)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let siblings = dict["siblings"] as? [[String: Any]] else { return nil }
            let total = siblings.reduce(Int64(0)) { sum, s in
                if let n = s["size"] as? NSNumber { return sum + n.int64Value }
                if let n = s["size"] as? Int      { return sum + Int64(n) }
                return sum
            }
            return total > 0 ? total : nil
        } catch {
            return nil
        }
    }
}

// MARK: - HFModelSummary

struct HFModelSummary: Identifiable, Hashable {
    let id: String                  // full repo id, e.g. "mlx-community/foo"
    let author: String              // namespace
    let modelName: String           // basename
    let downloads: Int
    let likes: Int
    let lastModified: Date?
    let tags: [String]
    let pipelineTag: String?

    init(json: [String: Any]) {
        let repoID = (json["modelId"] as? String)
                   ?? (json["id"]      as? String) ?? "unknown"
        self.id          = repoID
        let parts = repoID.split(separator: "/", maxSplits: 1).map(String.init)
        self.author      = parts.count == 2 ? parts[0] : ""
        self.modelName   = parts.last ?? repoID
        self.downloads   = (json["downloads"] as? Int) ?? 0
        self.likes       = (json["likes"]     as? Int) ?? 0
        self.tags        = (json["tags"]      as? [String]) ?? []
        self.pipelineTag = json["pipeline_tag"] as? String
        if let ts = json["lastModified"] as? String {
            let f = ISO8601DateFormatter()
            self.lastModified = f.date(from: ts)
        } else { self.lastModified = nil }
    }

    // MARK: - Convenience

    var hfURL: URL? { URL(string: "https://huggingface.co/\(id)") }

    var isMLX: Bool    { tags.contains("mlx") }
    var isCoreML: Bool { tags.contains("coreml") }
    var isGGUF: Bool   { tags.contains("gguf") }

    /// True when the repo is plausibly on-device usable on iOS.
    var isLikelyOnDeviceCompatible: Bool {
        isMLX || isCoreML
    }

    /// License tag if present (e.g. "license:apache-2.0").
    var licenseTag: String? {
        tags.first { $0.hasPrefix("license:") }?
            .replacingOccurrences(of: "license:", with: "")
    }

    static func == (lhs: HFModelSummary, rhs: HFModelSummary) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Number formatting helpers

extension Int {
    var compactCount: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        } else if self >= 1_000 {
            return String(format: "%.1fk", Double(self) / 1_000)
        }
        return "\(self)"
    }
}
