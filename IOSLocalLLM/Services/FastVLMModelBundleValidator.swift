import Foundation

// MARK: - FastVLMModelBundleValidator
// Checks for the presence of all FastVLM model assets in two locations:
//   1. The app bundle (compile-time resources)
//   2. The app's Documents/FastVLMModels/ folder (runtime-downloaded assets)
//
// This allows models to be added without recompiling the app.
// Run scripts/export_fastvlm_coreml.sh (or get_pretrained_mlx_model.sh for the LLM)
// and copy results to the Documents directory to enable the full pipeline.

struct FastVLMModelBundleValidator {

    // MARK: - Search paths

    /// All directories to scan for model assets, in priority order.
    static var searchDirectories: [URL] {
        var dirs: [URL] = []

        // 1. Documents/FastVLMModels/ — runtime-added assets take priority
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            dirs.append(docs.appendingPathComponent("FastVLMModels"))
        }

        // 2. App bundle root
        if let bundleURL = Bundle.main.resourceURL {
            dirs.append(bundleURL)
        }

        // 3. Bundle Models subfolder
        if let bundleURL = Bundle.main.resourceURL {
            dirs.append(bundleURL.appendingPathComponent("Models"))
        }

        return dirs
    }

    // MARK: - Validation entry point

    /// Validates all model assets and returns the component status.
    /// Non-throwing: missing assets result in .unloaded state; this is expected before download.
    static func validate() -> FastVLMComponentStatus {
        var status = FastVLMComponentStatus()

        // Encoder (fastvithd.mlpackage or .mlmodelc)
        status.encoder = fileExists(names: ["fastvithd.mlpackage", "fastvithd.mlmodelc"])
            ? .ready
            : .unloaded

        // Projector — either a standalone mlpackage or embedded in the MLX model directory
        let hasProjectorMLPackage = fileExists(names: [
            "multimodal_projector.mlpackage",
            "multimodal_projector.mlmodelc"
        ])
        let hasMLXModel = mlxModelDirectoryExists()
        status.projector = (hasProjectorMLPackage || hasMLXModel) ? .ready : .unloaded

        // Decoder — always via MLX (ml-fastvlm uses mlx-swift-examples MLXLLM, not Core ML)
        status.decoder = hasMLXModel ? .ready : .unloaded

        // Tokenizer
        let hasTokenizer = fileExists(names: [
            "tokenizer.json",
            "vocab.json"
        ])
        status.tokenizer = hasTokenizer ? .ready : .unloaded

        return status
    }

    // MARK: - URL resolution helpers

    /// Returns the URL for a named resource, searching all directories. Returns nil if not found.
    static func url(forResource name: String) -> URL? {
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Also try Bundle.main.url(forResource:) for compiled resources
        let parts = name.split(separator: ".", maxSplits: 1)
        if parts.count == 2 {
            return Bundle.main.url(forResource: String(parts[0]),
                                   withExtension: String(parts[1]))
        }
        return Bundle.main.url(forResource: name, withExtension: nil)
    }

    /// Returns the URL for the MLX model directory.
    ///
    /// Searches for any of the known MLX model directory names in priority order.
    /// The directory must contain `config.json` to be considered valid.
    static func mlxModelURL() -> URL? {
        // Candidate directory names in order of preference:
        //   1. "FastVLM-0.5B-fp16"  — bundled in the app (config + mlpackage, may lack weights)
        //   2. "llava-fastvithd_0.5b_stage3_llm.fp16"  — output of app/get_pretrained_mlx_model.sh
        //   3. "FastVLM-0.5B-CoreML"  — output of scripts/export_fastvlm_coreml.sh
        let knownDirNames = [
            "FastVLM-0.5B-fp16",
            FastVLMConfig.mlxModelDirectory,    // "llava-fastvithd_0.5b_stage3_llm.fp16"
            "llava-fastvithd_1.5b_stage3_llm.int8",
            "llava-fastvithd_7b_stage3_llm.int4",
            "FastVLM-0.5B-CoreML",
        ]

        for dir in searchDirectories {
            for name in knownDirNames {
                let candidate = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                   isDir.boolValue,
                   FileManager.default.fileExists(atPath: candidate.appendingPathComponent("config.json").path) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: - Private helpers

    private static func fileExists(names: [String]) -> Bool {
        names.contains { url(forResource: $0) != nil }
    }

    private static func mlxModelDirectoryExists() -> Bool {
        mlxModelURL() != nil
    }
}
