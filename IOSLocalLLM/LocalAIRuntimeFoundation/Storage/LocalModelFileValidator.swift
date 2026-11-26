import Foundation

// MARK: - LocalModelFileValidator

enum LocalModelFileValidator {
    struct ValidationResult: Equatable {
        var isSupported: Bool
        var failures: [String]

        static let supported = ValidationResult(isSupported: true, failures: [])
    }

    static func validateModelRoot(_ dir: URL) -> ValidationResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir),
              isDir.boolValue else {
            return .init(isSupported: false, failures: ["Directory does not exist."])
        }

        if hasCompleteGGUFVLMPair(in: dir) || hasValidGGUFTextModel(in: dir) {
            return .supported
        }

        guard let files = recursiveFiles(in: dir) else {
            return .init(isSupported: false, failures: ["Could not enumerate model directory."])
        }

        let names = Set(files.map(\.lastPathComponent))
        let hasConfig = names.contains("config.json") || names.contains("model_index.json")
        let hasTokenizer = names.contains("tokenizer.json")
            || names.contains("tokenizer_config.json")
            || names.contains("vocab.json")
        let weightFiles = files.filter { isRecognizedWeightFile($0.lastPathComponent) }
        guard hasConfig || hasTokenizer else {
            return .init(isSupported: false, failures: ["Missing config.json or tokenizer companion file."])
        }
        guard !weightFiles.isEmpty else {
            return .init(isSupported: false, failures: ["Missing model weights."])
        }
        let emptyWeights = weightFiles.filter { !isNonEmptyFile($0) }
        guard emptyWeights.isEmpty else {
            return .init(
                isSupported: false,
                failures: emptyWeights.map { "\($0.lastPathComponent) is empty." }
            )
        }
        if let shardFailure = validateSafetensorShards(in: dir, files: files) {
            return .init(isSupported: false, failures: [shardFailure])
        }
        return .supported
    }

    /// True when `dir` holds a model the MLX/safetensors **text** loader can
    /// actually load. Stricter than `validateModelRoot` on purpose: the
    /// swift-transformers `Hub.loadConfig` path hard-requires `tokenizer.json`
    /// and throws `configurationMissing("tokenizer.json")` without it — even
    /// when `config.json`, `tokenizer_config.json`, and weights are all present.
    /// `validateModelRoot` deliberately accepts a `tokenizer_config.json` /
    /// `vocab.json` companion as "has a tokenizer", so a snapshot missing only
    /// `tokenizer.json` passed as usable and was then loaded as a LOCAL
    /// directory (giving the loader no chance to fetch the missing file) — the
    /// "Qwen3-4B failed to load: Required configuration file missing:
    /// tokenizer.json" regression. GGUF models embed their tokenizer, so
    /// they're exempt. Callers that resolve a *pre-staged* MLX text model must
    /// use this, not the generic validator, so a tokenizer-less dir is rejected
    /// and the loader falls back to the repo-id config (HubApi then re-fetches
    /// only the missing file).
    static func isUsableMLXTextModelDirectory(_ dir: URL) -> Bool {
        guard validateModelRoot(dir).isSupported else { return false }
        guard let files = recursiveFiles(in: dir) else { return false }
        let names = Set(files.map { $0.lastPathComponent.lowercased() })
        if names.contains(where: { $0.hasSuffix(".gguf") }) { return true }  // GGUF embeds its tokenizer
        return names.contains("tokenizer.json")
    }

    static func hasCompleteGGUFVLMPair(in dir: URL) -> Bool {
        ggufLLM(in: dir) != nil && ggufProjector(in: dir) != nil
    }

    /// First valid LLM-weights GGUF (any `*.gguf` not prefixed `mmproj`)
    /// anywhere under `dir`, or nil. Single source of truth for the GGUF
    /// VLM load path: the readiness probe (`hasCompleteGGUFVLMPair`) and the
    /// loader (`LlamaCppVLMService.resolveLLMPath`) BOTH route through this, so
    /// a repo whose weights sit in a subfolder — or end in uppercase `.GGUF` —
    /// can never pass the probe yet fail to resolve at load.
    /// When supplied, `allowedFiles` restricts resolution to exact package paths.
    static func ggufLLM(in dir: URL, allowedFiles: [String]? = nil) -> URL? {
        firstValidGGUF(in: dir, allowedFiles: allowedFiles) { !$0.hasPrefix("mmproj") }
    }

    /// First valid vision-projector GGUF (`mmproj-*.gguf`) under `dir`, or nil.
    static func ggufProjector(in dir: URL, allowedFiles: [String]? = nil) -> URL? {
        firstValidGGUF(in: dir, allowedFiles: allowedFiles) { $0.hasPrefix("mmproj") }
    }

    /// Shared recursive, case-insensitive GGUF finder. `nameMatches` receives
    /// the lowercased filename. A folder can hold several quantizations of
    /// one model; directory order is unspecified, so candidates are ranked
    /// (4-bit first, then by name) to load the same file every time. Curated
    /// packages instead resolve their explicit paths in catalog order.
    private static func firstValidGGUF(
        in dir: URL,
        allowedFiles: [String]?,
        where nameMatches: (String) -> Bool
    ) -> URL? {
        // Curated packages specify exact relative paths. Never substitute an
        // imported or older quantization when the selected file is missing.
        if let allowedFiles {
            return allowedFiles.compactMap { path -> URL? in
                guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
                let url = dir.appendingPathComponent(path)
                guard url.pathExtension.lowercased() == "gguf",
                      nameMatches(url.lastPathComponent.lowercased()) else { return nil }
                return url
            }.first(where: isValidGGUFFile)
        }
        guard let files = recursiveFiles(in: dir) else { return nil }
        return files
            .filter { url in
                url.pathExtension.lowercased() == "gguf"
                    && nameMatches(url.lastPathComponent.lowercased())
            }
            .sorted { lhs, rhs in
                let lhsRank = ggufQuantizationRank(lhs.lastPathComponent)
                let rhsRank = ggufQuantizationRank(rhs.lastPathComponent)
                return lhsRank != rhsRank
                    ? lhsRank < rhsRank
                    : lhs.lastPathComponent < rhs.lastPathComponent
            }
            .first(where: isValidGGUFFile)
    }

    /// Quantizations in the order a phone should prefer them: 4-bit keeps
    /// quality while fitting the per-app memory limit.
    private static let ggufQuantizationPreference = [
        "q4_k_m", "q4_0", "q4_k_s", "q5_k_m", "q5_k_s", "q6_k", "q8_0",
    ]

    /// The preferred-quantization tag in `name`, if it carries one.
    static func ggufQuantizationTag(_ name: String) -> String? {
        let lower = name.lowercased()
        return ggufQuantizationPreference.first(where: lower.contains)
    }

    /// Lower is better; names without a known tag rank last.
    static func ggufQuantizationRank(_ name: String) -> Int {
        ggufQuantizationTag(name).flatMap(ggufQuantizationPreference.firstIndex(of:))
            ?? ggufQuantizationPreference.count
    }

    static func hasValidGGUFTextModel(in dir: URL) -> Bool {
        guard let files = recursiveFiles(in: dir) else { return false }
        let ggufs = files.filter { url in
            url.pathExtension.lowercased() == "gguf"
                && !url.lastPathComponent.lowercased().hasPrefix("mmproj")
        }
        return ggufs.contains(where: isValidGGUFFile)
    }

    static func isValidGGUFFile(_ url: URL) -> Bool {
        guard isNonEmptyFile(url),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data == Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    }

    static func isNonEmptyFile(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private static func recursiveFiles(in dir: URL) -> [URL]? {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                files.append(url)
            }
        }
        return files
    }

    private static func isRecognizedWeightFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".safetensors")
            || lower.hasSuffix(".npz")
            || lower.hasSuffix(".bin")
            || lower.hasSuffix(".gguf")
    }

    private static func validateSafetensorShards(in dir: URL, files: [URL]) -> String? {
        guard let indexURL = files.first(where: { $0.lastPathComponent == "model.safetensors.index.json" }) else {
            return nil
        }
        guard let required = requiredSafetensorShards(indexURL: indexURL), !required.isEmpty else {
            return nil
        }
        let present = Set(files.map(\.lastPathComponent))
        let missing = required.subtracting(present)
        if missing.isEmpty { return nil }
        return "Missing safetensor shard(s): \(missing.sorted().joined(separator: ", "))."
    }

    private static func requiredSafetensorShards(indexURL: URL) -> Set<String>? {
        guard
            let data = try? Data(contentsOf: indexURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let weightMap = json["weight_map"] as? [String: String]
        else { return nil }
        return Set(weightMap.values)
    }
}
