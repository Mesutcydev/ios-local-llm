import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXLMTransformers  // default TransformersLoader for loadContainer(from:configuration:)
import MLXVLM

// MARK: - FastVLMService
//
// Full multimodal pipeline: Core ML vision encoder (fastvithd.mlpackage)
// bridged to MLX Qwen2-0.5B decoder via Apple's FastVLM architecture.
//
// Architecture:
//   Image → fastvithd (Core ML) → [1,256,3072]
//         → FastVLMMultiModalProjector (MLX, 2×Linear+GELU) → [256,896]
//         → Qwen2-0.5B language model (MLX) → generated text
//
// This is implemented via the MLXVLM VLMModelFactory pipeline:
//   1. FastVLM.register() adds "llava_qwen2" and "LlavaProcessor" to VLMTypeRegistry
//   2. VLMModelFactory.loadContainer() loads language model + projector from MLX safetensors
//   3. FastVLM.sanitize() triggers lazy load of fastvithd Core ML model
//   4. generate() from MLXLMCommon runs the full autoregressive loop
//
// Model weights source:
//   Documents/FastVLMModels/<model-dir>/   (downloaded or copied by user)
//   Run scripts/export_fastvlm_coreml.sh or app/get_pretrained_mlx_model.sh.
//
// Reference: https://github.com/apple/ml-fastvlm/tree/main/app

@MainActor
final class FastVLMService: ObservableObject {

    // MARK: - Singleton

    static let shared = FastVLMService()

    /// Stable identifier used across the app to refer to "the FastVLM
    /// model" — keyed into MemoryAdvisor footprint estimates,
    /// ModelDownloadCenter entries, ModelUsageTracker records, etc.
    /// Centralised here so a rename only has to touch one site.
    nonisolated static let modelID = "fastvlm-mlx"

    // MARK: - Init / Deinit

    private var downloadObserver: NSObjectProtocol?

    private init() {
        // Auto-reload when the FastVLM MLX download completes
        downloadObserver = NotificationCenter.default.addObserver(
            forName: .hfModelDownloadCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let repoID = note.userInfo?["repoID"] as? String else { return }
            let normalized = repoID.lowercased()
            guard normalized.contains("fastvlm")
                    || normalized.contains("fastvithd")
                    || normalized.contains("llava")
            else { return }
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    deinit {
        if let o = downloadObserver { NotificationCenter.default.removeObserver(o) }
        generationTask?.cancel()
    }

    // MARK: - Published state

    @Published private(set) var componentStatus = FastVLMComponentStatus()
    @Published private(set) var isGenerating = false
    @Published private(set) var debugInfo: FastVLMDebugInfo?

    /// 0…1 progress for the active `load()` call. 0 before load starts and
    /// after it ends; the Models tab uses this to render a percentage bar
    /// next to the "Load model" button so the built-in FastVLM matches the
    /// custom-VLM progress UX.
    @Published private(set) var loadProgress: Double = 0
    /// Short human-readable hint that goes alongside the progress bar
    /// ("Preparing FastVLM…", "Downloading X%"). Mirrors the
    /// CodingAssistantService / MLXVisionService `.loading(String)` payload
    /// so the same parser can pull a percentage out of it.
    @Published private(set) var loadStatusMessage: String = ""

    // MARK: - Internal state

    private var modelContainer: ModelContainer?
    private var generationTask: Task<Void, Never>?
    private static var didRegister = false

    // MARK: - Load

    /// Loads the FastVLM pipeline.
    ///
    /// Steps:
    ///   1. Register `llava_qwen2` + `LlavaProcessor` with VLMModelFactory (once)
    ///   2. Locate the MLX model directory (Documents/ or bundle)
    ///   3. Load via VLMModelFactory — language model + projector from safetensors,
    ///      vision encoder from Core ML bundle (triggered in FastVLM.sanitize())
    ///
    /// If the model weights are not yet downloaded, all components report `.unloaded`
    /// with a clear message. The UI can then prompt the user to download.
    func load() async {
        // Re-entrancy guard. The download-completed observer and a manual
        // load can call load() concurrently; both would reach
        // loadContainer() since every await below yields the MainActor.
        // Mark .loading BEFORE the first await so the second caller sees it
        // (each early-return path below overwrites the status again).
        guard !componentStatus.isLoading else { return }
        componentStatus.encoder   = .loading
        componentStatus.projector = .loading
        componentStatus.decoder   = .loading
        componentStatus.tokenizer = .loading

        // FastVLM owns the Lens runtime exclusively. Drain the assistant,
        // downloaded MLX VLM, and llama.cpp VLM before any Core ML/MLX model
        // registration or load can allocate. The explicit gate wait covers
        // native Metal work that outlives Swift task cancellation.
        await CodingAssistantService.shared.unloadAndWaitForCleanup()
        MLXVisionService.shared.unload()
        await LlamaCppVLMService.shared.unloadAndWaitForCleanup()
        await MLXGenerationGate.shared.clearCacheWhenIdle()

        // Step 1: Register model types (idempotent)
        if !FastVLMService.didRegister {
            await FastVLM.register(modelFactory: VLMModelFactory.shared)
            FastVLMService.didRegister = true
        }

        // Step 2: Locate model directory
        guard let mlxDir = FastVLMModelBundleValidator.mlxModelURL() else {
            componentStatus.encoder   = .unloaded
            componentStatus.projector = .unloaded
            componentStatus.decoder   = .unloaded
            componentStatus.tokenizer = .unloaded
            return
        }

        // Step 3: Check for actual model weights (index.json alone is not enough)
        guard hasSafetensors(in: mlxDir) else {
            let msg = "FastVLM weights not downloaded yet. Open Settings → Download Models to fetch them."
            componentStatus.encoder   = .failed(msg)
            componentStatus.projector = .failed(msg)
            componentStatus.decoder   = .failed(msg)
            componentStatus.tokenizer = .failed(msg)
            return
        }

        // The MLX `Module` chain that drives the Core ML encoder is non-throwing
        // and uses `try!`, so a missing mlpackage at inference time fatally
        // crashes the app. Gate here, on the SAME path the stub initializer
        // reads from, so `modelContainer` stays nil and `analyze()` surfaces
        // a recoverable error to the UI.
        guard fastvithd.isEncoderInstalled else {
            let msg = "FastVLM Core ML encoder not installed. Download FastVLM in the Model Center."
            componentStatus.encoder   = .failed(msg)
            componentStatus.projector = .failed(msg)
            componentStatus.decoder   = .failed(msg)
            componentStatus.tokenizer = .failed(msg)
            return
        }

        // Memory advisor gate. Use the full safetyBlocker (thermal + physical
        // heuristic + the hard per-process ceiling) rather than verdict alone —
        // verdict reasons only about *physical* RAM (70% of device total) and
        // can pass on a device whose per-process cap is the real limit, letting
        // FastVLM SIGKILL on load. safetyBlocker enforces os_proc_available_memory
        // with the shared load-spike headroom, closing that gap.
        await MLXGenerationGate.shared.clearCacheWhenIdle()
        if let block = MemoryAdvisor.safetyBlocker(for: Self.modelID) {
            componentStatus.encoder   = .failed(block)
            componentStatus.projector = .failed(block)
            componentStatus.decoder   = .failed(block)
            componentStatus.tokenizer = .failed(block)
            return
        }

        // Step 3.5: Make sure swift-transformers' Hub.loadConfig and the
        // LlavaProcessor registry find every required file IN the model
        // directory. The downloaded MLX repos (apple/FastVLM-0.5B-MLX and
        // the mlx-community mirrors) ship config.json + safetensors but
        // omit tokenizer.json (Hub throws `configurationMissing`) and
        // preprocessor_config.json (the LlavaProcessor decode throws
        // "no such file"). We bundle both ourselves, so back-fill any
        // missing companion files from the bundle before handing off.
        ensureCompanionFiles(in: mlxDir)

        // Step 4: Mark as loading
        componentStatus.encoder   = .loading
        componentStatus.projector = .loading
        componentStatus.decoder   = .loading
        componentStatus.tokenizer = .loading
        loadProgress = 0
        loadStatusMessage = "Preparing FastVLM…"
        let loadStart = Date()

        // Step 5: Load via VLMModelFactory
        do {
            let config = ModelConfiguration(directory: mlxDir)
            // Gated so the Metal weight uploads can't race a concurrent
            // MLXVision load or a CodingAssistant generate.
            let container = try await MLXGenerationGate.shared.run { [weak self] in
                // Snapshot `weak self` into a local `let` so the inner
                // Task captures an immutable binding — silences the
                // Swift 6 "captured var 'self'" warning that fires when
                // a [weak self] capture is re-captured by a Sendable
                // closure inside.
                let weakSelf = self
                return try await VLMModelFactory.shared.loadContainer(
                    from: HubApiDownloader(),
                    configuration: config
                ) { progress in
                    let fraction = progress.fractionCompleted
                    let pct = Int(fraction * 100)
                    Task { @MainActor [weakSelf, fraction, pct] in
                        // Hops are unordered — drop stale fractions so the
                        // percentage can't render backwards.
                        guard let weakSelf,
                              fraction >= weakSelf.loadProgress else { return }
                        weakSelf.loadProgress = fraction
                        // Weights are local — every byte read is a "Preparing"
                        // step. (Network-down path doesn't apply here; the
                        // bundle and the Documents copy are both on-disk.)
                        weakSelf.loadStatusMessage = "Preparing \(pct)%"
                    }
                }
            }
            modelContainer = container
            let elapsedMs = Date().timeIntervalSince(loadStart) * 1000
            ModelUsageTracker.shared.recordLoadTime(modelID: Self.modelID, ms: elapsedMs)
            componentStatus.encoder   = .ready
            componentStatus.projector = .ready
            componentStatus.decoder   = .ready
            componentStatus.tokenizer = .ready
            loadProgress = 1
            loadStatusMessage = ""
            ToastCenter.shared.success("FastVLM ready")
        } catch is MLXGenerationGate.Cancelled {
            // App backgrounded or gate drained mid-load. Reset back to a
            // clean unloaded state — not a failure.
            componentStatus.encoder   = .unloaded
            componentStatus.projector = .unloaded
            componentStatus.decoder   = .unloaded
            componentStatus.tokenizer = .unloaded
            loadProgress = 0
            loadStatusMessage = ""
        } catch {
            let msg = error.localizedDescription
            componentStatus.encoder   = .failed(msg)
            componentStatus.projector = .failed(msg)
            componentStatus.decoder   = .failed(msg)
            componentStatus.tokenizer = .failed(msg)
            loadProgress = 0
            loadStatusMessage = ""
            ToastCenter.shared.error("FastVLM failed to load", detail: msg)
        }
    }

    // MARK: - Analyze (streaming)

    /// Runs the full FastVLM pipeline and streams generated tokens.
    ///
    /// The image is pre-processed by `FastVLMProcessor` (resize + center-crop + normalize),
    /// encoded by `fastvithd` (Core ML), projected by `FastVLMMultiModalProjector` (MLX),
    /// then decoded autoregressively by Qwen2-0.5B (MLX) with KV-cache.
    ///
    /// Throws `FastVLMError.decoderNotLoaded` when the model container is absent so the
    /// caller can fall back to OCR.
    func analyze(
        pixelBuffer: CVPixelBuffer,
        task: FastVLMTask,
        settings: FastVLMGenerationSettings
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let container = modelContainer else {
                continuation.finish(throwing: FastVLMError.decoderNotLoaded(
                    "FastVLM model not loaded. " +
                    "Download weights to Documents/FastVLMModels/ and call load() first."
                ))
                return
            }

            // Build UserInput: system message + user question + raw image
            let (systemPrompt, userText) = FastVLMPromptBuilder.promptParts(for: task)
            let userTextNoImageToken = userText
                .replacingOccurrences(of: FastVLMConfig.imageToken + "\n", with: "")
                .replacingOccurrences(of: FastVLMConfig.imageToken, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            // `nonisolated(unsafe)`: UserInput (and the CIImage it wraps) is not
            // Sendable, but it's built once here and only READ inside the
            // generation closure, whose Metal work is serialized through
            // MLXGenerationGate — there is no concurrent access to assert away.
            // This is the minimal, zero-behavior-change way to satisfy Swift 6's
            // capture check without refactoring the crash-sensitive vision path.
            nonisolated(unsafe) let userInput = UserInput(
                chat: [
                    .system(systemPrompt),
                    .user(userTextNoImageToken, images: [.ciImage(ciImage)])
                ]
            )

            let generateParams = GenerateParameters(
                maxTokens: settings.maxTokens,
                temperature: settings.temperature,
                topP: settings.topP,
                // mlx-swift-lm 3.31.3's TokenRing assumes prompt tokens are
                // one-dimensional. FastVLM correctly supplies batched
                // multimodal tokens shaped [1, sequenceLength], so enabling
                // its repetition processor corrupts the ring shape and the
                // next RepetitionContext logits lookup traps in MLX.getItem.
                // Keep the processor disabled until upstream handles batched
                // prompts; temperature and top-p sampling remain unchanged.
                repetitionPenalty: nil
            )

            // A second analyze() must not leave the previous generation
            // running concurrently — cancel it before handing over the slot
            // (mirrors CodingAssistantService.generate).
            generationTask?.cancel()
            generationTask = Task { [weak self] in
                guard let self else { return }
                self.isGenerating = true
                defer { self.isGenerating = false }

                do {
                    // generate() is synchronous; run inside actor-isolated perform.
                    // Wrapped in MLXGenerationGate so this can't race the
                    // MLXVisionService or CodingAssistantService Metal queue
                    // (concurrent submits → cbuf status Error → SIGABRT).
                    let result = try await MLXGenerationGate.shared.run { [container] in
                        // clearCache inside the gate so the next caller can't
                        // start a generate while we're freeing GPU buffers.
                        defer { mlxClearCache() }
                        return try await container.perform { context in
                            // `withError` installs a task-local handler in
                            // front of MLX's C error trampoline so any C++
                            // assertion (broadcast-shape mismatch, dtype
                            // error, etc.) becomes a catchable Swift throw
                            // instead of calling assertionFailure and
                            // killing the process.
                            //
                            // Before this wrap the v1.5.4 TestFlight build
                            // crashed with EXC_BREAKPOINT inside
                            // FastVLM.mergeInputIdsWithImageFeatures →
                            // MLXArray.subscript.setter → mlx_broadcast_to
                            // → _mlx_error → _assertionFailure when the
                            // image-token count in the prompt didn't match
                            // the vision model's feature count. Crash
                            // reported via TestFlight incident
                            // 119136B3-F74F-49EF-9F4C-BC9258EFD2A7.
                            //
                            // error.check() is called at the two natural
                            // break points where an error can be present
                            // without yet having terminated the call: after
                            // prepare (which sets up tensors), and after
                            // generate returns (in case the broadcast was
                            // deferred to the first token's prep step).
                            try await withError { error in
                                let lmInput = try await context.processor.prepare(input: userInput)
                                try error.check()
                                let stream = try generate(
                                    input: lmInput,
                                    parameters: generateParams,
                                    context: context
                                )
                                var info: GenerateCompletionInfo?
                                for await event in stream {
                                    if Task.isCancelled { break }
                                    switch event {
                                    case .chunk(let text):
                                        continuation.yield(text)
                                    case .info(let completion):
                                        info = completion
                                    case .toolCall:
                                        break
                                    }
                                }
                                try error.check()
                                // Return only the Sendable scalars the caller
                                // uses (below), not the whole non-Sendable
                                // GenerateCompletionInfo — that type crossing
                                // the gate/perform @Sendable boundary is a
                                // Swift 6 error. The metrics tuple is fully
                                // Sendable.
                                return (tokensPerSecond: info?.tokensPerSecond ?? 0,
                                        generationTokenCount: info?.generationTokenCount ?? 0)
                            }
                        }
                    }

                    await MainActor.run {
                        self.debugInfo = FastVLMDebugInfo(
                            encoderOutputShape: [1, 256, 3072],
                            projectorOutputShape: [256, FastVLMConfig.hiddenSize],
                            lastTokensPerSecond: result.tokensPerSecond,
                            lastTokenCount: result.generationTokenCount,
                            lastGenerationError: nil
                        )
                        ModelUsageTracker.shared.recordGeneration(
                            modelID: Self.modelID,
                            tokens: result.generationTokenCount,
                            tokensPerSecond: result.tokensPerSecond
                        )
                    }
                    continuation.finish()

                } catch is CancellationError {
                    // Task was cancelled — close the stream cleanly.
                    continuation.finish()
                } catch is MLXGenerationGate.Cancelled {
                    // Gate drained (background/memory pressure). Finish the
                    // stream without writing an error to debugInfo.
                    continuation.finish()
                } catch {
                    await MainActor.run {
                        self.debugInfo = FastVLMDebugInfo(
                            encoderOutputShape: nil,
                            projectorOutputShape: nil,
                            lastTokensPerSecond: nil,
                            lastTokenCount: nil,
                            lastGenerationError: error.localizedDescription
                        )
                    }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Control

    func stopGeneration() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    func unload() {
        // Same drain-before-clear pattern as CodingAssistantService.unload():
        // flushing the MLX buffer pool while a generation task is mid-Metal
        // command-buffer races the completion handler into
        // `mlx::core::gpu::check_error` and SIGABRTs. Cancel, drop the
        // container, then clear the pool only after the in-flight task
        // has actually ended.
        let inflight = generationTask
        generationTask = nil
        inflight?.cancel()
        isGenerating = false
        modelContainer = nil
        componentStatus = FastVLMComponentStatus()
        debugInfo = nil
        Task { @MainActor in
            _ = await inflight?.value
            await MLXGenerationGate.shared.clearCacheWhenIdle()
            autoreleasepool { }
        }
    }

    // MARK: - Helpers

    /// Returns true when the directory contains at least one .safetensors file.
    private func hasSafetensors(in directory: URL) -> Bool {
        Self.directoryHasSafetensors(directory)
    }

    /// Static mirror of `hasSafetensors` so `Self.installStatus()` can run from
    /// any thread without touching the @MainActor singleton.
    static func directoryHasSafetensors(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return contents.contains { $0.hasSuffix(".safetensors") }
    }

    /// Combined on-disk install state for FastVLM. The catalog's
    /// `DownloadableModel.isReady` only reflects the decoder safetensors
    /// downloader; the Core ML encoder mlpackage lives at a sibling path
    /// outside that downloader's destination. The picker and any "is FastVLM
    /// usable?" gate should consult this — not `isReady` — so a half-installed
    /// FastVLM can't be activated.
    static func installStatus() -> InstallStatus {
        let hasDecoder: Bool = {
            guard let mlxDir = FastVLMModelBundleValidator.mlxModelURL() else { return false }
            return directoryHasSafetensors(mlxDir)
        }()
        let hasEncoder = fastvithd.isEncoderInstalled
        switch (hasDecoder, hasEncoder) {
        case (true, true):   return .ready
        case (false, true):  return .decoderMissing
        case (true, false):  return .encoderMissing
        case (false, false): return .notInstalled
        }
    }

    enum InstallStatus: Equatable {
        case ready
        case encoderMissing
        case decoderMissing
        case notInstalled

        var isFullyInstalled: Bool { self == .ready }

        /// Short label suitable for a picker badge.
        var shortLabel: String {
            switch self {
            case .ready:          return "installed"
            case .encoderMissing: return "encoder missing"
            case .decoderMissing: return "decoder missing"
            case .notInstalled:   return "not installed"
            }
        }

        /// Long form for a toast / status card explaining the next step.
        var actionMessage: String {
            switch self {
            case .ready:
                return "FastVLM is installed."
            case .encoderMissing:
                return "FastVLM decoder is installed but the Core ML encoder is missing. Download it in the Model Center."
            case .decoderMissing:
                return "FastVLM Core ML encoder is installed but the MLX decoder weights are missing. Download them in the Model Center."
            case .notInstalled:
                return "FastVLM is not installed yet. Download it in the Model Center."
            }
        }
    }

    /// Back-fill tokenizer + image-processor companion files from the app
    /// bundle into the resolved MLX model directory when the downloaded repo
    /// omitted them. swift-transformers' `Hub.loadConfig` aborts the whole
    /// load if `tokenizer.json` is missing, and the LlavaProcessor registry
    /// aborts if `preprocessor_config.json` is missing — apple/FastVLM-0.5B-MLX
    /// (plus several mlx-community mirrors) ships only config.json +
    /// safetensors, so both files are absent. Symlinking would be cleaner but
    /// iOS sandbox semantics make cross-domain symlinks fragile across
    /// reinstalls; a one-time file copy is simpler and idempotent.
    private func ensureCompanionFiles(in directory: URL) {
        let fm = FileManager.default
        // tokenizer.json and preprocessor_config.json are REQUIRED by the
        // load path; the rest are optional but pulling them in for free
        // keeps tokenisation behaviour consistent with what FastVLM was
        // trained against.
        let companionFiles = [
            "tokenizer.json",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "vocab.json",
            "added_tokens.json",
            "preprocessor_config.json",
        ]
        for name in companionFiles {
            let destination = directory.appendingPathComponent(name)
            let bundled = FastVLMModelBundleValidator.url(forResource: name)
            // Decide whether the destination is acceptable as-is, or
            // needs to be replaced with the bundled copy.
            //
            // For tokenizer.json this is critical: the public
            // apple/FastVLM-0.5B-MLX repo (and most mlx-community
            // mirrors) ships a vanilla Qwen2 tokenizer that does
            // NOT declare `<image>` as an added/special token. That
            // makes tokenizer.encode("...<image>...") BPE-split the
            // literal text — no token equals 151646 in the output —
            // so FastVLM's merge step finds zero image positions and
            // the MLX scatter crashes with "Shapes (256,896) and
            // (1,0,896) cannot be broadcast". Our bundled
            // tokenizer.json has the right added_tokens; force-
            // replace the downloaded one when it's missing them.
            let needsReplace: Bool
            if !fm.fileExists(atPath: destination.path) {
                needsReplace = true
            } else if name == "tokenizer.json" || name == "added_tokens.json" {
                needsReplace = !fileDeclaresImageToken(destination)
            } else {
                needsReplace = false
            }
            guard needsReplace, let source = bundled else { continue }
            if source.standardizedFileURL == destination.standardizedFileURL { continue }
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                #if DEBUG
                print("[FastVLMService] Installed companion file \(name) from bundle")
                #endif
            } catch {
                print("[FastVLMService] Failed to copy \(name): \(error)")
            }
        }
    }

    /// True when the JSON file at `url` declares an `<image>` added/special
    /// token. Used by `ensureCompanionFiles` to decide whether a downloaded
    /// tokenizer.json is the FastVLM-aware variant (keep it) or a stock
    /// Qwen2 tokenizer (replace it with the bundled copy).
    private func fileDeclaresImageToken(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        // Cheap substring scan — parsing the full 11 MB tokenizer.json
        // every cold launch is wasteful when we only need a yes/no.
        // The added_tokens array stores entries like:
        //   { "id": 151646, "content": "<image>", ... }
        // so a literal `"<image>"` plus the canonical id is a reliable
        // positive signal across all variants we've seen on HF.
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"<image>\"")
    }
}

// MARK: - FastVLMError

enum FastVLMError: LocalizedError {

    case encoderNotLoaded(String)
    case projectorNotLoaded(String)
    case decoderNotLoaded(String)
    case tokenizerNotLoaded(String)

    case preprocessingFailed
    case encoderFailed(String)
    case projectorFailed(String)
    case decoderFailed(String)

    case modelNotFound
    case notLoaded

    /// The prompt's count of image-token placeholders didn't match the
    /// number of feature slots the vision encoder produced. Almost
    /// indicates the chat template injected the wrong number of
    /// `<image>` placeholders for the encoder's fixed 256-feature
    /// output. Thrown by FastVLM.mergeInputIdsWithImageFeatures
    /// before the MLX subscript broadcast — replaces the previous
    /// fatalError path that crashed TestFlight v1.5.4 build 1
    /// (incident 119136B3-F74F-49EF-9F4C-BC9258EFD2A7).
    case imageTokenCountMismatch(promptImageTokens: Int, visionFeatureSlots: Int)

    var errorDescription: String? {
        switch self {
        case .encoderNotLoaded(let msg):   return "Encoder not loaded: \(msg)"
        case .projectorNotLoaded(let msg): return "Projector not loaded: \(msg)"
        case .decoderNotLoaded(let msg):   return "Decoder not loaded: \(msg)"
        case .tokenizerNotLoaded(let msg): return "Tokenizer not loaded: \(msg)"
        case .preprocessingFailed:         return "Image preprocessing failed."
        case .encoderFailed(let msg):      return "Encoder inference failed: \(msg)"
        case .projectorFailed(let msg):    return "Projector inference failed: \(msg)"
        case .decoderFailed(let msg):      return "Decoder inference failed: \(msg)"
        case .modelNotFound:               return "fastvithd.mlpackage not found in bundle."
        case .notLoaded:                   return "FastVLM not loaded. Call load() first."
        case .imageTokenCountMismatch(let p, let v):
            return "FastVLM image-token mismatch: prompt has \(p) image tokens but the vision encoder produced \(v) feature slots. The chat template and encoder feature count disagree — reload the model or reinstall the FastVLM weights."
        }
    }
}
