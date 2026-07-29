import Foundation
import CoreML

// MARK: - fastvithd (Core ML stub)
// The Core ML auto-generated `fastvithd` class is normally produced by Xcode
// from `fastvithd.mlpackage` at build time. We exclude the source folder from
// the implicit sources scan (because it also contains config.json / tokenizer
// files that aren't ours to compile), so the auto-generated type isn't
// available. This stub gives `FastVLM.swift` a class with the same surface
// area and forwards to a hand-loaded `MLModel`.
//
// Where the encoder is found, in priority order:
//   1. Documents/FastVLMModels/fastvithd.mlmodelc     (or .mlpackage) — user
//      put it there manually, or a future download flow staged it
//   2. App bundle — pre-compiled `fastvithd.mlmodelc` shipped by the
//      `Compile and bundle FastVLM Core ML encoder` postCompileScript in
//      project.yml. This is the production path.
//   3. App bundle — raw `fastvithd.mlpackage` (fallback when coremlcompiler
//      wasn't available at build time; compiled at runtime via
//      `MLModel.compileModel(at:)` — costs ~2 s on first launch but is
//      functionally equivalent).
//
// Do not delete this file — removing it breaks compilation. If you want the
// auto-generated class back, drop the `**/FastVLM-0.5B-fp16/**` exclude in
// project.yml AND delete this stub.

@available(iOS 16.0, *)
final class fastvithd {

    /// Underlying Core ML model when one was found on disk. Stays nil in the
    /// stub-only path; `prediction(images:)` then throws.
    let model: MLModel?

    /// First URL that points to a usable Core ML encoder, walking the
    /// search list in priority order. Returns nil when nothing is on disk
    /// — callers should treat that as "encoder not installed" and present
    /// a recoverable error to the user instead of triggering the
    /// non-throwing MLX path that would `try!` into a crash.
    static var encoderURL: URL? {
        let fm = FileManager.default
        for candidate in encoderSearchURLs {
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Backwards-compatible accessor preserved for any existing reference.
    /// Equivalent to `encoderURL` for the .mlpackage case.
    static var encoderMLPackageURL: URL {
        encoderURL ?? documentsMLPackageURL()
    }

    /// True when SOMETHING usable was found — pre-compiled `.mlmodelc` in
    /// the bundle (production), raw `.mlpackage` in the bundle (fallback),
    /// or a user-placed copy under Documents/.
    static var isEncoderInstalled: Bool { encoderURL != nil }

    /// Default initializer — matches the auto-generated class signature.
    /// Loads from whichever encoder URL `encoderSearchURLs` finds first.
    /// `.mlpackage` is compiled on demand via `MLModel.compileModel`;
    /// `.mlmodelc` is loaded directly (zero compile cost).
    ///
    /// Compute units are pinned to Neural Engine + CPU (never GPU). Default
    /// `.all` routes this encoder through MetalPerformanceShadersGraph, which
    /// has SIGSEGV'd mid-`prediction` on iOS 27 / A19 (see diagnostics
    /// `CODELENS_SIGNAL SIGSEGV` → Espresso → MPSGraph). KittenTTS / Kokoro
    /// already use the same policy; keep FastVLM consistent.
    init() throws {
        guard let url = Self.encoderURL else {
            self.model = nil
            return
        }
        let config = Self.makeConfiguration()
        if url.pathExtension == "mlmodelc" {
            self.model = try MLModel(contentsOf: url, configuration: config)
        } else {
            let compiled = try MLModel.compileModel(at: url)
            self.model = try MLModel(contentsOf: compiled, configuration: config)
        }
    }

    /// Prefer ANE+CPU; drop to CPU-only when the device is already hot so we
    /// don't pile Neural Engine work on top of a fair/serious thermal state.
    private static func makeConfiguration() -> MLModelConfiguration {
        let config = MLModelConfiguration()
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            config.computeUnits = .cpuOnly
        default:
            config.computeUnits = .cpuAndNeuralEngine
        }
        return config
    }

    // MARK: - Search path

    /// Ordered list of locations to probe for the encoder. Defined here so
    /// the validator in `FastVLMModelBundleValidator` can stay in sync if
    /// it ever needs to surface "where did it find me" diagnostics.
    private static var encoderSearchURLs: [URL] {
        var urls: [URL] = []
        // 1. Documents/FastVLMModels — manual user install or future
        //    download flow that stages a private copy. Checked first so
        //    a newer encoder can override the bundled one if needed.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let docsRoot = docs.appendingPathComponent("FastVLMModels", isDirectory: true)
        urls.append(docsRoot.appendingPathComponent("fastvithd.mlmodelc"))
        urls.append(docsRoot.appendingPathComponent("fastvithd.mlpackage"))
        // 2. App bundle — pre-compiled mlmodelc (the production path).
        if let compiled = Bundle.main.url(forResource: "fastvithd", withExtension: "mlmodelc") {
            urls.append(compiled)
        }
        // 3. App bundle — raw mlpackage (fallback when coremlcompiler
        //    wasn't on PATH at build time). Runtime-compile.
        if let pkg = Bundle.main.url(forResource: "fastvithd", withExtension: "mlpackage") {
            urls.append(pkg)
        }
        return urls
    }

    private static func documentsMLPackageURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("FastVLMModels")
            .appendingPathComponent("fastvithd.mlpackage")
    }

    /// Wrapped Core ML prediction. Matches the auto-generated API surface used
    /// by `FastVLM.swift` (single `images` input, single `image_features`
    /// output). Throws when no on-disk model is available.
    func prediction(images: MLMultiArray) throws -> fastvithdOutput {
        guard let model else {
            throw NSError(domain: "fastvithd", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "FastVLM Core ML encoder weights not installed. Download FastVLM in the Model Center."
            ])
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["images": images])
        let output = try model.prediction(from: input)
        guard let arr = output.featureValue(for: "image_features")?.multiArrayValue else {
            throw NSError(domain: "fastvithd", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "FastVLM output is missing the expected 'image_features' field."
            ])
        }
        return fastvithdOutput(image_features: arr)
    }
}

/// Output struct matching the auto-generated `fastvithdOutput` shape.
struct fastvithdOutput {
    let image_features: MLMultiArray
}
