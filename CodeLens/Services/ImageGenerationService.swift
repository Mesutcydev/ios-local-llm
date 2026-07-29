import Foundation
import UIKit
import MLX
import MLXRandom
import Hub

// MARK: - ImageGenerationService
//
// On-device text-to-image generation via the MLX `StableDiffusion` library
// (mlx-swift-examples). FLUX is intentionally NOT offered: it isn't in the
// pinned MLX package and its 12B-parameter weights blow past the iOS
// per-process memory ceiling. The models exposed here use the SD / SDXL
// UNet + CLIP + VAE architecture the library actually supports, and run with
// `quantize` + `conserveMemory` so they fit on higher-tier devices.
//
// Lifecycle:
//   1. `download(_:)`   — pull weights via HubApi into Documents/huggingface
//   2. `generate(...)`  — load the generator, run the denoise loop
//                          inside MLXGenerationGate, decode, publish a UIImage
//
// All MLX GPU work funnels through `MLXGenerationGate.shared.run { }` so it
// never races the LLM / VLM Metal command queue (that race is an uncatchable
// C++ abort — see MLXGenerationGate). The assistant + vision models are
// unloaded before a generation so the diffusion weights have room.

@MainActor
final class ImageGenerationService: ObservableObject {

    static let shared = ImageGenerationService()

    // MARK: - Catalog

    struct Model: Identifiable, Equatable {
        let id: String                // HF repo id
        let displayName: String
        let subtitle: String
        let sizeLabel: String
        let approxRAMBytes: Int64
        let defaultSteps: Int
        let defaultCFG: Float
        /// Square latent edge; output image is 8× this per side.
        let latentEdge: Int
        let preset: StableDiffusionConfiguration.Preset

        var config: StableDiffusionConfiguration { preset.configuration }
        /// 8× the latent edge — the pixel dimension of the generated image.
        var pixelEdge: Int { latentEdge * 8 }

        static func == (lhs: Model, rhs: Model) -> Bool { lhs.id == rhs.id }
    }

    /// Curated, architecture-compatible image models. Kept deliberately short
    /// to the variants proven to load through this library — adding an
    /// arbitrary HF repo here only works if it ships the SD/SDXL
    /// `unet/ text_encoder/ vae/ tokenizer/` layout.
    nonisolated static let catalog: [Model] = [
        Model(
            id: "stabilityai/sdxl-turbo",
            displayName: "SDXL Turbo",
            subtitle: "stabilityai/sdxl-turbo · 1–4 steps, very fast",
            sizeLabel: "~6.9 GB",
            approxRAMBytes: 5_200_000_000,   // staged 8-bit load + 512² activation peak
            defaultSteps: 2,
            defaultCFG: 0,
            latentEdge: 64,                   // 512² output
            preset: .sdxlTurbo
        ),
        Model(
            id: "stabilityai/stable-diffusion-2-1-base",
            displayName: "Stable Diffusion 2.1",
            subtitle: "stabilityai/stable-diffusion-2-1-base · 512², detailed",
            sizeLabel: "~5.2 GB",
            approxRAMBytes: 2_600_000_000,   // quantized + conserveMemory working set
            defaultSteps: 20,
            defaultCFG: 7.5,
            latentEdge: 64,                   // 512² output
            preset: .base
        ),
        Model(
            id: "stabilityai/sd-turbo",
            displayName: "SD-Turbo",
            subtitle: "stabilityai/sd-turbo · 1 step, ungated, lightest",
            sizeLabel: "~5.0 GB",
            approxRAMBytes: 2_600_000_000,   // SD 2.1 architecture (same as above)
            defaultSteps: 1,
            defaultCFG: 0,
            latentEdge: 64,                   // 512² output
            preset: .sdTurbo
        ),
        Model(
            id: "stable-diffusion-v1-5/stable-diffusion-v1-5",
            displayName: "Stable Diffusion 1.5",
            subtitle: "stable-diffusion-v1-5 · 512², classic, versatile",
            sizeLabel: "~4.3 GB",
            approxRAMBytes: 2_500_000_000,   // SD 1.5 UNet (~0.86B), quantized
            defaultSteps: 20,
            defaultCFG: 7.5,
            latentEdge: 64,                   // 512² output
            preset: .sd15
        ),
        Model(
            id: "Lykon/dreamshaper-8",
            displayName: "DreamShaper 8",
            subtitle: "Lykon/dreamshaper-8 · SD 1.5 fine-tune, artistic",
            sizeLabel: "~4.3 GB",
            approxRAMBytes: 2_500_000_000,   // SD 1.5 architecture (same as above)
            defaultSteps: 25,
            defaultCFG: 7,
            latentEdge: 64,                   // 512² output
            preset: .dreamShaper8
        ),
        // Segmind-Vega / SSD-1B ship `mid_block_type: "UNetMidBlock2D"` — a plain
        // mid block with NO cross attention. They used to crash this loader, which
        // hardcoded a cross-attention mid `Transformer2D` (feeding 2048-d SDXL
        // conditioning into a mismatched matmul). `UNetMidBlock` now builds that
        // attention only when `mid_block_type != "UNetMidBlock2D"`, so both load.
        Model(
            id: "segmind/Segmind-Vega",
            displayName: "Segmind Vega",
            subtitle: "segmind/Segmind-Vega · distilled SDXL (~0.74B), fast",
            sizeLabel: "~6.0 GB",
            approxRAMBytes: 2_800_000_000,   // distilled SDXL UNet, quantized + conserve
            defaultSteps: 20,
            defaultCFG: 7,
            latentEdge: 64,                   // 512² output
            preset: .vega
        ),
        // NOTE: SSD-1B has asymmetric per-block transformer depths
        // (`reverse_transformer_layers_per_block`, e.g. [4,4,10]) that this
        // single-depth-per-block loader does not special-case. The mid-block fix
        // clears its documented crash; verify it loads on-device before relying
        // on it (remove this entry if the weights don't match).
        Model(
            id: "segmind/SSD-1B",
            displayName: "Segmind SSD-1B",
            subtitle: "segmind/SSD-1B · distilled SDXL (~1.3B), higher quality",
            sizeLabel: "~8.3 GB",
            approxRAMBytes: 3_400_000_000,   // distilled SDXL UNet, quantized + conserve
            defaultSteps: 20,
            defaultCFG: 7.5,
            latentEdge: 64,                   // 512² output
            preset: .ssd1b
        ),
    ]

    nonisolated static func model(forID id: String) -> Model? { catalog.first { $0.id == id } }

    // MARK: - State

    enum State: Equatable {
        case idle
        case downloading(Double)        // 0–1
        case loading
        case ready
        case generating(Double)         // 0–1 over denoise steps
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var selectedModelID: String = "stabilityai/sd-turbo"
    @Published private(set) var image: UIImage?
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var directDownloadProgress: [String: Double] = [:]
    @Published private(set) var directDownloadErrors: [String: String] = [:]

    var selectedModel: Model {
        Self.model(forID: selectedModelID) ?? Self.catalog[0]
    }

    // MARK: - Private

    /// HubApi carrying the user's Hugging Face token (when present AND the
    /// `useHFToken` toggle is on) so auth-required / gated diffusion repos
    /// actually download — without this the image downloader sent no token and
    /// 401'd even though the assistant's token was valid. Built fresh per use
    /// because the token can change at runtime; `downloadBase` stays the
    /// default (Documents/huggingface) so installed-path lookups are unchanged.
    private var hub: HubApi {
        HubApi(hfToken: HFTokenStore.shared.isActive ? HFTokenStore.shared.currentToken() : nil)
    }
    private var genTask: Task<Void, Never>?
    private var directDownloadTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Installed-state helpers

    /// Local directory HubApi downloads this repo into
    /// (`Documents/huggingface/models/<repo>`).
    func repoDirectory(_ repoID: String) -> URL {
        hub.localRepoLocation(Hub.Repo(id: repoID))
    }

    /// True when every file the StableDiffusion preset needs is present.
    ///
    /// A previous/resumed download can leave a repo with only one large weight
    /// file (often the UNet) on disk. Treating that as installed sends the
    /// loader into missing config/tokenizer files and surfaces a cryptic
    /// "config.json couldn't be found" error instead of repairing the cache.
    func isInstalled(_ model: Model) -> Bool {
        missingRequiredFiles(for: model).isEmpty
    }

    private func requiredFilePaths(for model: Model) -> [String] {
        Array(Set(model.config.files.values)).sorted()
    }

    private func missingRequiredFiles(for model: Model) -> [String] {
        let dir = repoDirectory(model.id)
        return requiredFilePaths(for: model).filter { rel in
            let url = dir.appendingPathComponent(rel)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else {
                return true
            }
            return size <= 0
        }
    }

    /// Allocated on-disk size of a downloaded image model, 0 if absent.
    func installedBytes(_ model: Model) -> Int64 {
        let dir = repoDirectory(model.id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        return (try? FileManager.default.allocatedSizeOfDirectory(at: dir)) ?? 0
    }

    /// Combined on-disk size of every installed image model.
    var totalInstalledBytes: Int64 {
        Self.catalog.reduce(0) { $0 + installedBytes($1) }
    }

    // MARK: - Selection

    func select(_ id: String) {
        guard id != selectedModelID else { return }
        selectedModelID = id
        if case .generating = state { } else {
            state = isInstalled(selectedModel) ? .ready : .idle
        }
    }

    // MARK: - Download

    /// Starts a weights-only download without loading the model or generating
    /// an image. The Models screen uses this for setup cards, where "Get"
    /// should mean exactly that and should not require a prompt.
    func startDownload(_ model: Model) {
        guard !isInstalled(model), directDownloadProgress[model.id] == nil else { return }

        directDownloadErrors[model.id] = nil
        directDownloadProgress[model.id] = 0
        directDownloadTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            await self.downloadOnly(model)
            self.directDownloadTasks[model.id] = nil
        }
    }

    func isDownloading(_ model: Model) -> Bool {
        directDownloadProgress[model.id] != nil
    }

    func downloadProgress(for model: Model) -> Double {
        directDownloadProgress[model.id] ?? 0
    }

    private func downloadOnly(_ model: Model) async {
        do {
            try await downloadViaCoordinator(model) { [weak self] fraction in
                self?.directDownloadProgress[model.id] = fraction
            }
            directDownloadProgress[model.id] = nil
            directDownloadErrors[model.id] = nil
            objectWillChange.send()
            ToastCenter.shared.success("Downloaded \(model.displayName)")
        } catch {
            directDownloadProgress[model.id] = nil
            directDownloadErrors[model.id] = Self.downloadFailureMessage(for: model, error: error)
            ToastCenter.shared.error(
                "Download failed",
                detail: directDownloadErrors[model.id] ?? error.localizedDescription
            )
        }
    }

    func deleteModel(_ model: Model) {
        let dir = repoDirectory(model.id)
        try? FileManager.default.removeItem(at: dir)
        if model.id == selectedModelID { state = .idle }
        objectWillChange.send()
    }

    // MARK: - Generation

    func cancel() {
        genTask?.cancel()
        genTask = nil
        Task { await MLXGenerationGate.shared.cancelAll() }
        if case .generating = state { state = isInstalled(selectedModel) ? .ready : .idle }
        if case .loading = state { state = isInstalled(selectedModel) ? .ready : .idle }
        if case .downloading = state { state = .idle }
    }

    /// Download (if needed), load, and generate an image for `prompt`.
    func generate(prompt: String,
                  negativePrompt: String = "",
                  steps: Int? = nil,
                  seed: UInt64? = nil) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ToastCenter.shared.info("Enter a prompt first")
            return
        }
        guard genTask == nil else { return }
        let model = selectedModel
        genTask = Task { [weak self] in
            await self?.runGeneration(model: model,
                                       prompt: trimmed,
                                       negativePrompt: negativePrompt,
                                       steps: steps ?? model.defaultSteps,
                                       seed: seed)
            await MainActor.run { self?.genTask = nil }
        }
    }

    private func runGeneration(model: Model,
                               prompt: String,
                               negativePrompt: String,
                               steps: Int,
                               seed: UInt64?) async {
        Diagnostics.shared.breadcrumb(
            "imagegen start · \(model.id) · steps=\(steps) · avail=\(MemoryAdvisor.availableMemoryForModel.formattedBytes)",
            category: "imagegen")

        // 0. Crash-aware adaptive sizing. A jetsam/OOM kill is uncatchable — the
        //    process just dies, so the do/catch below never sees it. Instead we
        //    learn from it across launches: a marker persisted right before the
        //    heavy work (and cleared on any normal/throwing exit) survives only a
        //    crash, so a leftover marker on the next run means the last attempt
        //    died. We then step this model's latent size down one rung — or, once
        //    it bottoms out, refuse it with an actionable message instead of
        //    crash-looping. First-run behaviour is unchanged: with no prior crash
        //    there's no learned cap and generation proceeds at full resolution.
        absorbPreviousCrashIfAny()
        if isCrashBlocked(model.id) {
            Diagnostics.shared.warning(
                "imagegen refused — crash-blocked \(model.id)", category: "imagegen")
            state = .failed(Self.crashBlockedMessage(for: model))
            return
        }
        // 1. Free RAM/GPU held by OTHER models — and any previous diffusion
        //    run's pooled buffers — BEFORE measuring. This must happen first:
        //    otherwise a model that just ran (e.g. SDXL-Turbo) leaves weights
        //    resident, `processAvailableMemory` reads artificially low, and a
        //    SMALLER model like SD 2.1 gets wrongly refused ("~3.0 GB needed,
        //    ~2.6 GB free") even though it would comfortably fit once the
        //    previous model is released.
        // Await the assistant LLM's FULL teardown (it's the largest consumer
        // and the most likely to be mid-generate). Plain `unload()` returns
        // before its deferred cache clear runs when a generation is in flight,
        // leaving multi-GB weights resident when the gate measures below —
        // exactly the "smaller model wrongly refused" case this block exists
        // to prevent. The VLM unloads stay synchronous (no awaitable variant),
        // but the explicit gated clear + the assistant await reclaim the
        // bulk of the memory before measurement.
        await CodingAssistantService.shared.unloadAndWaitForCleanup()
        MLXVisionService.shared.unload()
        FastVLMService.shared.unload()
        // Flush MLX's idle buffer pool now. The clear shares the global gate,
        // so cancelled VLM Metal work must drain before reclamation and before
        // the memory measurement below.
        await MLXGenerationGate.shared.clearCacheWhenIdle()

        // 2. Memory gate — the real per-process ceiling on iOS. Diffusion's
        //    transient load peak is high; refuse rather than SIGKILL.
        //
        // The needed figure is the model's curated peak resident working set.
        // Do NOT use the installed directory size here: Hugging Face repos can
        // contain multiple large components / stale downloaded files, and that
        // disk footprint is not the live RAM peak. Using it here inflated SDXL
        // Turbo to ~14 GB needed on devices where the measured working set fits.
        let avail = MemoryAdvisor.availableMemoryForModel
        let needed = model.approxRAMBytes + MemoryAdvisor.loadHeadroomReserve
        guard avail <= 0 || avail >= needed else {
            let needGB = Double(needed) / 1_000_000_000
            let haveGB = Double(avail) / 1_000_000_000
            Diagnostics.shared.warning(
                "imagegen refused — low memory (need ~\(String(format: "%.1f", needGB))GB, have ~\(String(format: "%.1f", haveGB))GB)",
                category: "imagegen")
            state = .failed(String(
                format: "Not enough memory for %@ (~%.1f GB needed, ~%.1f GB free). Close other apps and retry.",
                model.displayName, needGB, haveGB))
            return
        }
        // When memory measurement is unavailable (avail == 0, uncommon on
        // device), refuse anyway with a conservative floor — an unsized
        // model is safer to block than to let through into a likely OOM.
        if avail <= 0 {
            Diagnostics.shared.warning(
                "imagegen refused — memory measurement unavailable, blocking conservatively",
                category: "imagegen")
            state = .failed("Could not measure available memory. Close other apps, restart, and retry.")
            return
        }

        // 3. Download any missing preset files (weights, configs, tokenizers).
        if !isInstalled(model) {
            state = .downloading(0)
            statusMessage = "Downloading \(model.displayName)…"
            let missing = missingRequiredFiles(for: model)
            if !missing.isEmpty {
                Diagnostics.shared.breadcrumb(
                    "imagegen repairing incomplete install · \(model.id) · missing=\(missing.joined(separator: ","))",
                    category: "imagegen")
            }
            do {
                try await downloadViaCoordinator(model) { [weak self] frac in
                    guard let self else { return }
                    if case .downloading = self.state { self.state = .downloading(frac) }
                }
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain,
                   ns.code == NSURLErrorNotConnectedToInternet,
                   isInstalled(model) {
                    // Offline but already cached — proceed to load.
                } else {
                    Diagnostics.shared.error(
                        "imagegen download failed · \(model.id) · \(error)", category: "imagegen")
                    state = .failed(Self.downloadFailureMessage(for: model, error: error))
                    return
                }
            }
        }
        let missingAfterDownload = missingRequiredFiles(for: model)
        guard missingAfterDownload.isEmpty else {
            Diagnostics.shared.error(
                "imagegen missing required files after download · \(model.id) · \(missingAfterDownload.joined(separator: ","))",
                category: "imagegen")
            state = .failed(
                "Download is incomplete for \(model.displayName). Missing \(missingAfterDownload.prefix(3).joined(separator: ", ")). Retry the download."
            )
            return
        }
        guard !Task.isCancelled else { state = .ready; return }

        // 3b. Background guard (mirrors the VLM describe path). The download
        //     above can run for minutes; the user often locks the screen or
        //     switches apps while it runs. Firing the Stable Diffusion load +
        //     denoise now would submit Metal command buffers from the
        //     background, which iOS kills with
        //     kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted —
        //     an UNCATCHABLE C++ abort that takes the whole app down (the
        //     "crash while downloading image models" report). The weights are
        //     on disk now; leave the model ready and let the user tap Generate
        //     again once the app is foreground.
        guard UIApplication.shared.applicationState == .active,
              !DeviceSafetyMonitor.shared.shouldStopHeavyWork else {
            state = isInstalled(model) ? .ready : .idle
            statusMessage = isInstalled(model)
                ? "Downloaded — tap Generate to create your image."
                : ""
            Diagnostics.shared.breadcrumb(
                "imagegen deferred — app not active / unsafe after download",
                category: "imagegen")
            return
        }

        // Keep the screen awake for the load + denoise so auto-lock can't
        // background the app mid-generation and trip the same Metal abort.
        // Generation is seconds (not the multi-minute download, which we
        // deliberately DON'T pin awake — the background URLSession handles it).
        DeviceSafetyMonitor.shared.setKeepAwake(true, reason: "image-gen")
        defer { DeviceSafetyMonitor.shared.setKeepAwake(false, reason: "image-gen") }

        // Resolve the working latent size: the model default, lowered to any cap
        // this device learned from a previous crash. Persist what we're about to
        // attempt so an OOM kill during it is detectable on the next launch; the
        // defer clears the marker on every normal or throwing exit (a jetsam kill
        // reaches neither, leaving the marker for recovery).
        let effectiveLatentEdge = min(model.latentEdge,
                                      learnedSafeCap(for: model.id) ?? model.latentEdge)
        markGenerationInFlight(model: model.id, cap: effectiveLatentEdge)
        defer { clearGenerationInFlight() }
        if effectiveLatentEdge != model.latentEdge {
            Diagnostics.shared.breadcrumb(
                "imagegen downsized after prior crash · \(model.id) · latent=\(effectiveLatentEdge) (was \(model.latentEdge))",
                category: "imagegen")
        }

        // 4. Load + generate, serialized against all other MLX work.
        state = .loading
        statusMessage = "Loading \(model.displayName)…"
        do {
            // Return PNG Data (Sendable) from the gate — CGImage / UIImage are
            // not reliably Sendable across the actor boundary.
            let availForCap = avail
            let pngData = try await MLXGenerationGate.shared.run { () -> Data in
                // Bound MLX's allocator for the duration of THIS generation only.
                // CodeLensApp deliberately leaves the cache unbounded globally —
                // a low global cap starves the resident LLM and triggers Metal
                // command-buffer churn. But here the assistant + VLM were already
                // unloaded above, so nothing else is competing: we cap the cache
                // (32 MiB) and the working set so freed UNet buffers return to iOS
                // instead of lingering in the allocator pool and stacking under
                // the float32 VAE decode — the jetsam OOM that kills the app right
                // at "100%" (denoise done, only the decode left). Without this,
                // MLX's unbounded pool + the decode peak overrun the per-process
                // limit under memory pressure. Restored on exit so the LLM's next
                // load sees MLX's default unbounded cache again.
                // (This mirrors the working TokenAI app's `tuneMLXMemory`.)
                let prevCacheLimit = MLX.Memory.cacheLimit
                let prevMemoryLimit = MLX.Memory.memoryLimit
                // Always set a hard MLX memory ceiling — never leave it
                // unbounded, even when the live measurement is unavailable
                // (availForCap == 0 on simulator or early boot). Without
                // this limit, MLX's unbounded allocator can push the process
                // past the per-process ceiling and trigger a jetsam OOM kill
                // — the exact crash this code path suffered during image
                // generation on iPhone 18,2 (12 GB device, ~6.2 GB entitled
                // per-process cap, SDXL Turbo ~5.2 GB working set + load
                // spike exceeding available headroom).
                //
                // The cushion covers the transient load spike (on-disk read,
                // float16→8-bit quantization, Metal upload) that briefly
                // doubles the resident weight pages. 1 GB empirically fits
                // SDXL Turbo and SD 2.1 on an entitled 12 GB device.
                let limit: Int64
                if availForCap > 0 {
                    // measured headroom minus load-spike cushion, floored
                    // at 1 GB so small-positive values still get a limit
                    let cushion: Int64 = 1_024 * 1024 * 1024
                    limit = max(1_024 * 1024 * 1024, Int64(availForCap) - cushion)
                } else {
                    // no measurement available — use a conservative ceiling
                    // so MLX stays within the per-process limit on an
                    // average device without starving the generation
                    limit = 2_048 * 1024 * 1024
                }
                MLX.Memory.memoryLimit = Int(limit)
                MLX.Memory.cacheLimit = 32 * 1024 * 1024
                defer {
                    MLX.Memory.cacheLimit = prevCacheLimit
                    MLX.Memory.memoryLimit = prevMemoryLimit
                }

                // Always load fresh. `conserveMemory` (set below) DISCARDS the
                // model inside performTwoStage, so a container is single-use:
                // caching and reusing one would throw `.modelDiscarded` on the
                // next generation.
                let load = LoadConfiguration(float16: true, quantize: true)
                let container = try SDModelContainer<TextToImageGenerator>
                    .createTextToImageGenerator(configuration: model.config,
                                                 loadConfiguration: load)
                await container.setConserveMemory(true)

                var builder = model.config.defaultParameters()
                builder.prompt = prompt
                builder.negativePrompt = negativePrompt
                builder.steps = max(1, steps)
                builder.seed = seed ?? UInt64.random(in: 0...UInt64.max)
                builder.latentSize = [effectiveLatentEdge, effectiveLatentEdge]
                // Capture an immutable copy in the @Sendable stage closures —
                // capturing the mutable `var` is a hard error under Swift 6.
                let params = builder

                // Run the ENTIRE denoise loop in the first stage so the UNet is
                // actually freed before the VAE decode. `DenoiseIterator`
                // strongly retains the whole model (UNet + text encoders) via
                // its `sd` reference, so it must go out of scope before
                // performTwoStage's conserveMemory discard can release them.
                // `detachedDecoder()` captures only the (float32) VAE, so the
                // second stage decodes with the UNet already gone.
                //
                // This is the OOM (jetsam) fix: previously the loop AND the
                // decode both ran in the second stage, leaving the UNet
                // resident during the float32 VAE decode — a 512² memory spike
                // that silently SIGKILLed both models regardless of their size.
                let totalSteps = params.steps
                let raster: MLXArray = try await container.performTwoStage(
                    first: { generator -> (ImageDecoder, MLXArray) in
                        let decoder = generator.detachedDecoder()
                        var lastXt: MLXArray?
                        var i = 0
                        for xt in generator.generateLatents(parameters: params) {
                            if Task.isCancelled { break }
                            // Release the prior step's array before building the
                            // next so per-step memory doesn't accumulate (the
                            // mlx-swift-examples reference does the same).
                            lastXt = nil
                            eval(xt)
                            lastXt = xt
                            i += 1
                            let frac = Double(i) / Double(max(totalSteps, 1))
                            Task { @MainActor [weak self] in
                                self?.state = .generating(frac)
                            }
                        }
                        guard let lastXt else { throw MLXGenerationGate.Cancelled() }
                        eval(lastXt)
                        return (decoder, lastXt)
                    },
                    second: { pair -> MLXArray in
                        let (decoder, latent) = pair
                        let decoded = decoder(latent)
                        let r = (decoded * 255).asType(.uint8).squeezed()
                        eval(r)
                        return r
                    }
                )
                // `Image` here is StableDiffusion's raster type (this file does
                // not import SwiftUI, so there's no ambiguity with SwiftUI.Image).
                let cg = SDImage(raster).asCGImage()
                guard let data = UIImage(cgImage: cg).pngData() else {
                    throw NSError(domain: "ImageGen", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Could not encode the generated image."
                    ])
                }
                return data
            }

            image = UIImage(data: pngData)
            state = .ready
            statusMessage = ""
            Diagnostics.shared.breadcrumb("imagegen done · \(model.id)", category: "imagegen")
            HapticManager.impact(.medium)
            ToastCenter.shared.success("Image generated")

        } catch is MLXGenerationGate.Cancelled {
            Diagnostics.shared.breadcrumb("imagegen cancelled", category: "imagegen")
            state = isInstalled(model) ? .ready : .idle
        } catch is CancellationError {
            Diagnostics.shared.breadcrumb("imagegen cancelled", category: "imagegen")
            state = isInstalled(model) ? .ready : .idle
        } catch {
            Diagnostics.shared.error("imagegen failed · \(error.localizedDescription)", category: "imagegen")
            state = .failed(error.localizedDescription)
            ToastCenter.shared.error("Image generation failed",
                                     detail: error.localizedDescription)
        }
    }

    // MARK: - Resilient download

    /// Downloads each file the StableDiffusion preset needs, one at a time,
    /// through `BackgroundDownloadCoordinator` — the same downloader every LLM
    /// model already uses — so a mid-file network drop resumes from URLSession
    /// resume data instead of restarting from byte 0.
    ///
    /// Why this exists: the image-gen path used to call the raw HubApi snapshot
    /// (`config.download`), which (a) had no retry at all — a single `-1005
    /// "network connection lost"`, which Hugging Face's xet CDN throws routinely
    /// partway through a multi-GB transfer, aborted the whole download — and
    /// (b) DELETES the partial `.incomplete` file on every retry, so a drop at
    /// 95% of the UNet weights restarted that file from scratch. The coordinator
    /// persists resume data per URL and continues where the transfer broke.
    ///
    /// Files land at `localRepoLocation/<relativePath>` — exactly where the
    /// loader's `resolve()` and `isInstalled()` already read them — so nothing
    /// downstream changes, and models previously pulled via HubApi keep working
    /// (present non-empty files are skipped, not re-fetched).
    ///
    /// Caveat inherited from the coordinator: a GATED repo (SD 2.1) sends an
    /// `Authorization` header, and URLSession resume data can't re-encode
    /// headers, so those downloads still restart on a drop. The ungated models
    /// (SD-Turbo, SD 1.5, DreamShaper, SSD-1B, Vega) — the ones that actually
    /// fail in the field — get true mid-file resume.
    private func downloadViaCoordinator(
        _ model: Model,
        progress: @escaping (Double) -> Void
    ) async throws {
        let dir = repoDirectory(model.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // `config.files` is internal but in-module here; we only need the
        // relative paths (e.g. "unet/diffusion_pytorch_model.safetensors").
        let relPaths = requiredFilePaths(for: model)
        let total = max(relPaths.count, 1)
        var done = 0

        // Monotonic progress floor. A resumed/retried file restarts its byte
        // count from the last resume-data checkpoint (which lags the live
        // count), and a background URLSession buffers progress callbacks across
        // a lock/unlock — both make the raw fraction step backwards, which the
        // user sees as the bar "flickering between 47% and 51%" (the lock
        // point). Clamp so the reported fraction never decreases: the bar holds
        // at its peak while a resumed file re-fetches the gap, then advances.
        let floor = ProgressFloor()
        let report: (Double) -> Void = { raw in
            if raw > floor.value { floor.value = raw }
            progress(floor.value)
        }

        for rel in relPaths {
            // A user cancel returns between files (the in-flight URLSession
            // transfer keeps going in the background and is reused next time);
            // the caller's `Task.isCancelled` check then takes the cancel path.
            if Task.isCancelled { return }

            let dest = dir.appendingPathComponent(rel)
            // Already on disk → count and skip. The coordinator only writes to
            // `dest` on success (atomic move), so a present non-empty file is
            // always complete; partials live in the resume sidecar, not here.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               let size = attrs[.size] as? Int64, size > 0 {
                done += 1
                report(Double(done) / Double(total))
                continue
            }

            let encoded = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
            guard let url = URL(string: "https://huggingface.co/\(model.id)/resolve/main/\(encoded)") else {
                throw URLError(.badURL)
            }

            let fileIndex = done   // immutable copy for the @escaping progress closure
            let maxAttempts = 4
            var attempt = 0
            while true {
                do {
                    _ = try await BackgroundDownloadCoordinator.shared.download(
                        from: url, to: dest, expectedSize: 0
                    ) { written, expected in
                        let inFile = expected > 0 ? min(Double(written) / Double(expected), 1) : 0
                        report((Double(fileIndex) + inFile) / Double(total))
                    }
                    break
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    guard attempt < maxAttempts, Self.isRetryableDownloadError(error) else { throw error }
                    Diagnostics.shared.breadcrumb(
                        "imagegen download retry \(attempt)/\(maxAttempts - 1) · \(model.id) · \(rel) · \(error.localizedDescription)",
                        category: "imagegen")
                    try? await Task.sleep(nanoseconds: Self.downloadRetryDelayNs(attempt: attempt))
                }
            }
            done += 1
            report(Double(done) / Double(total))
        }
    }

    /// Reference box for the monotonic download-progress floor. A class (not a
    /// captured `var`) so the coordinator's `@escaping` progress closure shares
    /// one mutable cell cleanly, and so the floor is scoped per download call
    /// (two concurrent direct downloads don't clobber each other's floor).
    private final class ProgressFloor { var value = 0.0 }

    /// Whether a download error is a transient transfer hiccup worth retrying.
    /// Mirrors HFModelDownloadManager's policy. `BackgroundDownloadCoordinator`
    /// surfaces HTTP failures as domain `"HFDownload"` with the status code as
    /// `code` (429 / 5xx are transient; 401/403/404 are permanent → gated/auth,
    /// handled by `isGatedAccessError`) and network-layer drops as
    /// `NSURLErrorDomain`. `notConnectedToInternet` is deliberately excluded —
    /// runGeneration handles the steady-state offline case (proceed if already
    /// installed) and retrying it just adds latency.
    private static func isRetryableDownloadError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "HFDownload" {
            return ns.code == 429 || (500...599).contains(ns.code)
        }
        guard ns.domain == NSURLErrorDomain else { return false }
        switch ns.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable,
             NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }

    /// Exponential backoff with ±25% jitter for retry number `attempt` (1-based):
    /// ~1.5 s, 3 s, 6 s, capped at 30 s. Same shape as the general downloader.
    private static func downloadRetryDelayNs(attempt: Int) -> UInt64 {
        let base = 1.5 * pow(2, Double(attempt - 1))
        let jittered = base * Double.random(in: 0.75...1.25)
        return UInt64(min(jittered, 30) * 1_000_000_000)
    }

    // MARK: - Error messaging

    /// Turns an opaque HubApi download failure into actionable guidance. The
    /// most common real-world cause is a GATED model (e.g. Stable Diffusion
    /// 2.1): the token is valid, but the account hasn't accepted the repo's
    /// license, so Hugging Face returns a 404 that HubApi surfaces as the
    /// cryptic "File not found: main" (the `/revision/main` listing call).
    private static func downloadFailureMessage(for model: Model, error: Error) -> String {
        guard isGatedAccessError(error) else {
            return "Download failed: \(error.localizedDescription)"
        }
        if !HFTokenStore.shared.isActive {
            return "\(model.displayName) is a gated model. Add a Hugging Face token in Settings (and turn on “Use HF token”), then accept the license at huggingface.co/\(model.id) and retry."
        }
        return "\(model.displayName) is a gated model. Your token is valid, but its Hugging Face account must accept the license once: open huggingface.co/\(model.id), sign in, tap “Agree and access repository”, then retry."
    }

    /// True when a download error looks like a gated / auth / access problem
    /// (vs. a network drop or disk error).
    private static func isGatedAccessError(_ error: Error) -> Bool {
        if let hub = error as? Hub.HubClientError {
            switch hub {
            case .fileNotFound, .resourceNotFound, .authorizationRequired:
                return true
            case .httpStatusCode(let code):
                return [401, 403, 404].contains(code)
            default:
                return false
            }
        }
        let ns = error as NSError
        return [401, 403, 404].contains(ns.code)
    }

    /// Drop any queued GPU work (keeps weights on disk). Called when the app
    /// needs the RAM back for the LLM / VLM. The diffusion container is
    /// single-use and never held past a generation, so there's nothing to
    /// release here beyond draining the gate.
    func unload() {
        Task { await MLXGenerationGate.shared.cancelAll() }
        if case .generating = state { state = isInstalled(selectedModel) ? .ready : .idle }
    }

    // MARK: - Crash-aware adaptive sizing
    //
    // A jetsam / OOM kill is uncatchable: the process dies with no Swift error,
    // so the only way to "learn" from it is across launches. Right before the
    // heavy diffusion work we persist a marker of what we're attempting; a
    // normal completion or any thrown error clears it, but a crash does not. On
    // the next run a leftover marker means the last attempt died, so we step the
    // offending model's latent size down one rung — and once it bottoms out,
    // block the model with an actionable message instead of crash-looping.
    //
    // Everything here is namespaced to image generation (its own UserDefaults
    // keys, only read/written on this path) and is inert until an actual crash
    // occurs — so it changes no other feature and no first-run behaviour.

    private static let inFlightKey = "codelensImgGenInFlight"            // "<modelID>|<latentEdge>"
    private static func safeLatentKey(_ id: String) -> String { "codelensImgSafeLatent_\(id)" }
    private static func blockedKey(_ id: String) -> String { "codelensImgBlocked_\(id)" }

    /// Descending latent rungs (all multiples of 8 — the VAE upsamples 8×, so
    /// the output edge is 8× these: 512², 320², 192²). A crash at one rung drops
    /// to the next; a crash at the floor blocks the model.
    private static let latentLadder = [64, 40, 24]

    /// Fold any crash the previous run left unrecorded into a lower safe cap for
    /// that model (or block it, if it already crashed at the smallest rung).
    private func absorbPreviousCrashIfAny() {
        let d = UserDefaults.standard
        guard let marker = d.string(forKey: Self.inFlightKey) else { return }
        d.removeObject(forKey: Self.inFlightKey)
        let parts = marker.split(separator: "|")
        guard parts.count == 2, let crashedCap = Int(parts[1]) else { return }
        let id = String(parts[0])
        if let next = Self.latentLadder.first(where: { $0 < crashedCap }) {
            let prior = d.integer(forKey: Self.safeLatentKey(id))
            let newCap = prior == 0 ? next : min(prior, next)
            d.set(newCap, forKey: Self.safeLatentKey(id))
            Diagnostics.shared.warning(
                "imagegen recovered from prior crash · \(id) · crashedLatent=\(crashedCap) → safeLatent=\(newCap)",
                category: "imagegen")
        } else {
            d.set(true, forKey: Self.blockedKey(id))
            Diagnostics.shared.warning(
                "imagegen blocked after crash at floor · \(id) · latent=\(crashedCap)",
                category: "imagegen")
        }
    }

    private func learnedSafeCap(for id: String) -> Int? {
        let v = UserDefaults.standard.integer(forKey: Self.safeLatentKey(id))
        return v > 0 ? v : nil
    }

    private func isCrashBlocked(_ id: String) -> Bool {
        UserDefaults.standard.bool(forKey: Self.blockedKey(id))
    }

    private func markGenerationInFlight(model id: String, cap: Int) {
        UserDefaults.standard.set("\(id)|\(cap)", forKey: Self.inFlightKey)
        UserDefaults.standard.synchronize()   // a crash/jetsam kill runs no cleanup
    }

    private func clearGenerationInFlight() {
        UserDefaults.standard.removeObject(forKey: Self.inFlightKey)
    }

    /// User-facing "this model won't run here" message, with a concrete next step
    /// (suggest the lightest other installed model that hasn't been blocked).
    private static func crashBlockedMessage(for model: Model) -> String {
        let lighter = catalog
            .filter { $0.id != model.id
                && !UserDefaults.standard.bool(forKey: blockedKey($0.id))
                && shared.isInstalled($0) }
            .min(by: { $0.approxRAMBytes < $1.approxRAMBytes })
        let suggestion = lighter.map { " Try \($0.displayName) instead." }
            ?? " Try a lighter model (e.g. Stable Diffusion 1.5)."
        return "\(model.displayName) ran out of memory on this device more than once, so it's been disabled to stop the crash loop.\(suggestion)"
    }

    /// Forget everything learned from prior crashes (safe caps + blocks) so every
    /// model gets a clean retry — e.g. after the user frees up the device. Not
    /// called automatically; wire to a Settings affordance if desired.
    func resetImageModelLimits() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.inFlightKey)
        for model in Self.catalog {
            d.removeObject(forKey: Self.safeLatentKey(model.id))
            d.removeObject(forKey: Self.blockedKey(model.id))
        }
        Diagnostics.shared.breadcrumb("imagegen adaptive limits reset", category: "imagegen")
    }
}
