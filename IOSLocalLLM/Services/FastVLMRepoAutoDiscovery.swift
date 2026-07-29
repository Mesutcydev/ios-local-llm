import Foundation

// MARK: - FastVLMRepoAutoDiscovery
// Probes a hand-curated list of HuggingFace candidate repos for FastVLM
// weights, returns the first one that responds with HTTP 200. Used on launch
// so the user never has to figure out the right repo ID themselves.
//
// Strategy:
//   1. Try the currently-saved fastVLMRepoID first (it might already work).
//   2. Try a list of historically-known FastVLM mirrors in priority order.
//   3. Fall back to a live HuggingFace search for "fastvlm" pinned to MLX.
//   4. Persist whichever wins to AppSettings.fastVLMRepoID.
//
// All calls are HEAD/light JSON queries — no actual model bytes downloaded
// during discovery.

@MainActor
final class FastVLMRepoAutoDiscovery {

    static let shared = FastVLMRepoAutoDiscovery()
    private init() {}

    /// Curated candidates in priority order. The first one that responds
    /// HTTP 200 wins.
    static let candidates: [String] = [
        "apple/FastVLM-0.5B-MLX",
        "mlx-community/llava-fastvithd_0.5b_stage3_llm.fp16",
        "apple/FastVLM-0.5B",
        "mlx-community/FastVLM-0.5B-Stage3-LLM",
        "mlx-community/llava-fastvithd_0.5b_stage3_llm.bf16",
        "apple/FastVLM-1.5B-MLX",
    ]

    /// Discovers a working FastVLM repo. Persists the choice to AppSettings
    /// and returns the resolved ID. Returns nil if nothing in the candidate
    /// list responded.
    func discover() async -> String? {
        let stored = AppSettings.shared.fastVLMRepoID
        var triedOrder: [String] = []
        if !stored.isEmpty { triedOrder.append(stored) }
        triedOrder.append(contentsOf: Self.candidates.filter { $0 != stored })

        for repoID in triedOrder {
            if await isAccessible(repoID) {
                if AppSettings.shared.fastVLMRepoID != repoID {
                    AppSettings.shared.fastVLMRepoID = repoID
                    print("[FastVLMRepoAutoDiscovery] picked \(repoID)")
                }
                return repoID
            }
        }

        // Last-ditch: try a live HF search for "fastvlm" and pick the top
        // public hit. If even that fails we surface nil and the UI handles it.
        if let searched = await searchFastVLM() {
            AppSettings.shared.fastVLMRepoID = searched
            print("[FastVLMRepoAutoDiscovery] discovered via search: \(searched)")
            return searched
        }

        return nil
    }

    // MARK: - HTTP probes

    /// Returns true when /api/models/{repoID} returns 200.
    private func isAccessible(_ repoID: String) async -> Bool {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)")
        else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("ios-local-llm/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Runs an HF search filtered to MLX, sorted by downloads, returns the
    /// first hit whose name contains "fastvlm".
    private func searchFastVLM() async -> String? {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        comps.queryItems = [
            URLQueryItem(name: "search",    value: "fastvlm"),
            URLQueryItem(name: "limit",     value: "10"),
            URLQueryItem(name: "sort",      value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "filter",    value: "mlx"),
        ]
        guard let url = comps.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("ios-local-llm/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return nil
            }
            // Pick the first hit that explicitly names "fastvlm"
            for item in json {
                if let id = (item["modelId"] as? String) ?? (item["id"] as? String),
                   id.lowercased().contains("fastvlm") {
                    return id
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}
