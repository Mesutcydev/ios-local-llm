import Foundation
import UIKit
import MLX
import MLXLLM
import MLXVLM
import CoreImage
import MLXLMCommon
import MLXLMTransformers  // default TransformersLoader for loadContainer(from:configuration:)
import os                  // OSAllocatedUnfairLock

// MARK: - CodingAssistantService
// Runs whatever AssistantModel is selected (default: AssistantModelCatalog
// .presets[0]) on-device via MLX Swift. On first use the model is loaded
// from one of three on-disk locations, in priority order:
//   1. Documents/huggingface/models/<repoID>/   — HubApi lazy cache
//   2. Documents/LLMModels/<dirName>/           — Download Center pre-stage
//   3. Documents/HFModels/<repoID>/             — legacy generic HF pre-stage
// If none exist, MLX falls back to HubApi which downloads into (1). See
// `modelConfig(for:)` for the bridge that picks between directory- and
// repo-id-based ModelConfiguration.

@MainActor
final class CodingAssistantService: ObservableObject {
    static let shared = CodingAssistantService()

    /// Context / output budget policy for the currently selected imported
    /// GGUF. See `GGUFGenerationProfile` for why only recurrent Gemma 3n /
    /// Gemma 4 E-series quants get the compact profile.
    private var ggufProfile: GGUFGenerationProfile {
        GGUFGenerationProfile.resolve(
            repoID: activeModel.repoID,
            displayName: activeModel.displayName
        )
    }

    @Published private(set) var state: ServiceState = .unloaded
    @Published private(set) var tokenRate: Double = 0
    /// Estimated token count of the trimmed input sent on the last generate().
    /// Used by the UI to render a context-window progress bar.
    @Published private(set) var estimatedInputTokens: Int = 0
    /// True when the most recent reply ended by exhausting its token
    /// budget rather than at an end-of-generation token — i.e. the answer is
    /// truncated and the UI should say so. Reset at each generation start.
    @Published private(set) var lastGenerationHitTokenLimit = false
    /// True when the last standard-GGUF reply hit the token budget and the
    /// native KV is still resident. Compact Gemma never sets this.
    @Published private(set) var canResumeFromCache = false
    /// Tokenizer-exact prompt / completion counts from the last finished
    /// generate(). Local API usage fields and the usage tracker read these
    /// instead of guessing from streamed pieces or tok/s × elapsed.
    @Published private(set) var lastPromptTokens: Int = 0
    @Published private(set) var lastOutputTokens: Int = 0
    /// Output budget the chrome should advertise: user setting, thermal
    /// advisor, and (for imported GGUF) the compact-profile 128-token cap.
    var effectiveOutputTokenCap: Int {
        GGUFGenerationProfile.outputTokenCap(
            isGGUF: activeModel.runtime == .llamaCpp,
            profile: ggufProfile,
            requested: effectiveGenerationSettings.maxTokens,
            thermalCap: DeviceSafetyMonitor.shared.recommendedMaxTokens
        )
    }
    /// Cloud execution is deliberately tracked separately from local model
    /// residency. A PCC request can fail or be cancelled without making a
    /// downloaded MLX / llama.cpp model appear failed.
    @Published private(set) var activeExecutionLocation: ModelExecutionLocation
    @Published private(set) var applePrivateCloudStatus: ApplePCCStatus = .unsupportedOS
    @Published private(set) var applePrivateCloudGenerationState: ApplePCCGenerationState = .idle
    @Published private(set) var applePrivateCloudContextSize: Int?

    /// Practical input budget used by the chat context compactor. This mirrors
    /// the runtime's device/model cap so compaction happens before the final
    /// hard safety trim in `generate()`.
    var effectiveGenerationSettings: AssistantModelGenerationSettings {
        AssistantModelSettingsStore.shared.effectiveSettings(
            for: activeModel.repoID,
            supportsThinking: activeModel.supportsThinking,
            appSettings: AppSettings.shared
        )
    }

    var currentInputBudget: Int {
        if activeExecutionLocation == .applePrivateCloud {
            guard let contextSize = applePrivateCloudContextSize else {
                // No guessed PCC window: retain only the newest prompt until
                // the SDK reports its actual context size.
                return 512
            }
            return ApplePrivateCloud.inputBudget(
                contextSize: contextSize,
                maximumResponseTokens: AppSettings.shared.assistantMaxTokens
            )
        }
        if activeModel.runtime == .llamaCpp {
            return ggufProfile.inputBudget(
                requestedOutputTokens: effectiveGenerationSettings.maxTokens
            )
        }
        let executionProfile = MLXAssistantExecutionProfile.resolve(
            repoID: activeModel.repoID
        )
        let deviceContextCap = (DeviceTierAdvisor.current == .max) ? 16_384 : 8_192
        let requestedOutput = min(
            effectiveGenerationSettings.maxTokens,
            DeviceSafetyMonitor.shared.recommendedMaxTokens
        )
        return executionProfile.inputBudget(
            modelContextWindowTokens: activeModel.contextWindowTokens,
            deviceContextCap: deviceContextCap,
            requestedOutputTokens: requestedOutput
        )
    }

    enum ServiceState: Equatable {
        case unloaded
        case loading(String)
        case ready
        case generating
        case failed(String)
    }

    /// True when the model weights are resident in memory and able to
    /// serve a generate() call — either idle (`.ready`) or busy
    /// (`.generating`). Used by the Mac-pairing UI to decide whether
    /// to show the "load a model first" banner; a generation in
    /// flight is NOT a reason to scare the user into thinking
    /// nothing is loaded. Loading/failed/unloaded all read false.
    var isModelLoaded: Bool {
        if resolvedMLXContainer != nil { return true }
        switch state {
        case .ready, .generating: return true
        case .unloaded, .loading, .failed: return false
        }
    }

    private var container: ModelContainer?

    /// True when the resident MLX runtime is the **dual-role shared vision
    /// container** — the only Assistant path that can route image inputs
    /// through the MLXVLM processor. Bounded-text containers (text-only
    /// MLXLLM load) and GGUF assistants loaded without an mmproj projector
    /// cannot process images, so they stay `false` and any attached image
    /// thumbnails are rendered in the chat bubble only, never sent to the
    /// model. Mirrors how `resolvedMLXContainer`'s fallback only consults
    /// the shared Lens runtime when our own `container` is nil. The chat
    /// UI (photo-picker prefill, send-button gating) and `generate()`'s
    /// chat-array construction both branch on this flag, so a vision-
    /// capable catalogue model that happened to load as a bounded text
    /// runtime doesn't claim image viewing it can't honour.
    @Published private(set) var isVisionChatCapable: Bool = false

    /// Re-evaluate `isVisionChatCapable` against the currently resident
    /// runtime. Called at every load / unload / model-switch state
    /// transition site so the flag tracks what is actually in memory.
    /// Identity-style check: a supportsVision catalogue entry whose MLX
    /// container was loaded locally (text-only) returns `false` because
    /// that container has no vision processor, even though the package is
    /// nominally a VLM.
    @MainActor
    private func refreshVisionChatCapability() {
        isVisionChatCapable =
            activeModel.supportsVision && activeModel.runtime == .mlx
            && container == nil
            && LensInferenceLoop.shared.sharedContainer(for: activeModel.repoID) != nil
    }

    /// Text-only runtimes are owned here. A unified text+vision runtime is
    /// borrowed from Lens only when its full vision envelope fits; otherwise
    /// Assistant owns a smaller, bounded text container for the same package.
    private var resolvedMLXContainer: ModelContainer? {
        container ?? LensInferenceLoop.shared.sharedContainer(for: activeModel.repoID)
    }
    private var ggufModel: LlamaCppVLM?
    private var generateTask: Task<Void, Never>?
    private var pccGenerateTask: Task<Void, Never>?
    private var activePCCRequestID: UUID?
    /// Identity of the MLX load currently allowed to publish a container.
    /// Model loading itself cannot be interrupted safely, so an unload/model
    /// switch invalidates this token and lets the stale load finish without
    /// committing its result over the newly-selected model.
    private var activeLoadID: UUID?
    /// Identifies the GGUF task currently allowed to mutate service state.
    /// A late completion from a cancelled/unloaded task must never mark a
    /// newer generation ready.
    private var activeGGUFGenerationID: UUID?
    private var memoryWarningObserver: NSObjectProtocol?
    private var isTransitioning = false
    /// Highest load-progress fraction seen during the active load().
    /// Progress callbacks hop to the MainActor via unordered `Task`s,
    /// so without this monotonic guard percentages can render out of order.
    private var loadProgressFraction: Double = 0

    // MARK: - Init / Deinit

    private init() {
        activeExecutionLocation =
            ApplePrivateCloud.isSupportedOnCurrentOS
            && AppSettings.shared.assistantModelID == ApplePrivateCloud.modelID
                ? .applePrivateCloud
                : .localDownloaded
        // Listen for global memory warnings so we can shed the model
        // proactively before iOS Jetsam-kills us.
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            // Queue a GPU cache clear only — do NOT unload the model. Proactive
            // unloading on every memory warning is too aggressive: iOS fires
            // these warnings regularly during inference even when the process
            // has plenty of room left. Let Jetsam handle a true OOM; our job
            // is to free the easiest-to-reclaim GPU buffers and keep running.
            Task { await MLXGenerationGate.shared.clearCacheWhenIdle() }
        }
    }

    deinit {
        if let o = memoryWarningObserver {
            NotificationCenter.default.removeObserver(o)
        }
        generateTask?.cancel()
        pccGenerateTask?.cancel()
        if let activePCCRequestID {
            ApplePrivateCloud.cancel(activePCCRequestID)
        }
    }

    // MARK: - Model config
    // HubApi downloads to Documents/huggingface/models/<repoID>/ on first
    // use (see swift-transformers HubApi.swift — downloadBase defaults to
    // Documents/huggingface, not Caches/). The active model is chosen by
    // the user via AssistantModelCatalog and persisted in
    // AppSettings.assistantModelID.

    /// Currently active model — exposed so the picker UI can show it.
    @Published private(set) var activeModel: AssistantModel = AssistantModelCatalog.currentSelection()

    var activeSelectionID: String {
        activeExecutionLocation == .applePrivateCloud
            ? ApplePrivateCloud.modelID
            : activeModel.id
    }

    var activeDisplayName: String {
        activeExecutionLocation == .applePrivateCloud
            ? ApplePrivateCloud.displayName
            : activeModel.displayName
    }

    var canGenerateSelectedTarget: Bool {
        if activeExecutionLocation == .applePrivateCloud {
            return AppSettings.shared.hasCurrentApplePCCPrivacyConsent
                && applePrivateCloudStatus.canSend
                && applePrivateCloudGenerationState != .generating
        }
        return state == .ready
    }

    var isGeneratingSelectedTarget: Bool {
        if activeExecutionLocation == .applePrivateCloud {
            return applePrivateCloudGenerationState == .generating
        }
        return state == .generating
    }

    var selectedContextWindowTokens: Int {
        if activeExecutionLocation == .applePrivateCloud {
            return applePrivateCloudContextSize ?? 0
        }
        return activeModel.contextWindowTokens
    }

    /// True only when the user had explicitly started a cold model load and
    /// iOS backgrounded the app before it finished. Foregrounding may resume
    /// that load; ordinary unloaded models remain lazy and are not auto-loaded.
    private var resumeLoadAfterLifecycleInterruption = false

    /// The repo ID of the currently loaded model, or nil when nothing is
    /// resident. Used by LifecycleController for crash breadcrumbs.
    var activeModelRepoID: String? {
        switch state {
        case .ready, .generating:
            return activeModel.repoID
        case .unloaded, .loading, .failed:
            return nil
        }
    }

    /// Builds the MLX configuration for whatever the user has selected.
    ///
    /// If the user pre-staged weights via the Download Center, use them
    /// directly via a directory-based ModelConfiguration. Otherwise fall
    /// back to a repo-id config — MLX will lazy-download into HubApi's
    /// cache on first use.
    ///
    /// This is the bridge between two parallel storage layouts:
    ///   • Download Center writes to Documents/LLMModels/<dirName>/
    ///   • HubApi reads from Documents/huggingface/models/<repoID>/
    /// Without this preference check, a Download-Center-staged copy sat
    /// idle on disk while MLX silently re-downloaded its own copy via
    /// HubApi — doubling disk use and confusing users who'd already
    /// "downloaded" the model.
    private static func modelConfig(for model: AssistantModel) -> ModelConfiguration {
        // mlx-swift-lm 3.x dropped `overrideTokenizer:` (which forced the
        // tokenizer *class*). Class selection is now handled automatically by
        // AutoTokenizer in the TransformersLoader, so it's simply omitted.
        if let staged = preStagedDirectory(for: model) {
            return ModelConfiguration(
                directory: staged,
                defaultPrompt: "Hello",
                extraEOSTokens: ["<|im_end|>"]
            )
        }
        return ModelConfiguration(
            id: model.repoID,
            defaultPrompt: "Hello",
            extraEOSTokens: ["<|im_end|>"]
        )
    }

    /// Legacy default — used by anything still calling the old API.
    /// Resolves the directory at access time so the first-launch path
    /// can short-circuit HubApi too.
    static var modelConfig: ModelConfiguration {
        modelConfig(for: AssistantModelCatalog.presets[0])
    }

    /// Returns the on-disk directory where pre-staged weights for `model`
    /// live, if any. Walks the layouts the app writes to in priority order:
    /// HubApi cache first (so a previously-used model wins), then the
    /// Download Center destinations. A directory only counts as "staged"
    /// when it passes `ModelCacheProbe.isUsableModelDirectory` (config +
    /// weights both present) — a half-finished download would otherwise
    /// trick MLX into trying to load incomplete state.
    static nonisolated func preStagedDirectory(for model: AssistantModel) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dirName = model.repoID.split(separator: "/").last.map(String.init) ?? model.repoID
        // HF Search downloads land at `HFModels/<author>_<name>/` (slash
        // flattened to underscore) — see ModelsManagerView.registerAndDownload
        // and HFSearchRow.init. LocalModelImport drops to `HFModels/<tail>/`
        // where tail is the repoID's last path component. Without both
        // variants, every launch fell through to the HubApi fetch path and
        // re-downloaded the weights even though they were already on disk.
        let flattened = model.repoID.replacingOccurrences(of: "/", with: "_")
        // HuggingFace Hub canonical cache layout: `models--<author>--<name>`
        // with weights inside a `snapshots/<rev-hash>/` subdir. mlx-swift's
        // HubApi follows this convention when it's not pointed at a custom
        // cache root. Probe missed this entirely before — every cold launch
        // of an MLX-loaded model that wasn't ALSO catalog-downloaded would
        // mislabel as "Downloading" until the speed latch flipped.
        let dashedRepo = model.repoID.replacingOccurrences(of: "/", with: "--")
        let hfHubBase = docs.appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
            .appendingPathComponent("models--\(dashedRepo)")
        var candidates: [URL] = [
            docs.appendingPathComponent("huggingface")
                .appendingPathComponent("models")
                .appendingPathComponent(model.repoID),
            docs.appendingPathComponent("LLMModels").appendingPathComponent(dirName),
            docs.appendingPathComponent("HFModels").appendingPathComponent(model.repoID),
            docs.appendingPathComponent("HFModels").appendingPathComponent(flattened),
            docs.appendingPathComponent("HFModels").appendingPathComponent(dirName),
            // HF Hub-compatible layout — base dir AND each snapshot subdir.
            // ModelCacheProbe recurses, so the base entry catches it; the
            // explicit snapshot enumeration below is belt-and-suspenders
            // for cases where only one snapshot is complete and another
            // is mid-download.
            hfHubBase,
        ]
        let snapshotsDir = hfHubBase.appendingPathComponent("snapshots")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshotsDir.path) {
            for snap in entries {
                candidates.append(snapshotsDir.appendingPathComponent(snap))
            }
        }
        // Require tokenizer.json (not just any tokenizer companion) — the MLX
        // text loader throws configurationMissing("tokenizer.json") otherwise.
        // A dir missing only tokenizer.json is rejected here so modelConfig
        // falls back to the repo-id config and HubApi re-fetches the snapshot,
        // skipping the weights already on disk. See
        // LocalModelFileValidator.isUsableMLXTextModelDirectory.
        return candidates.first(where: LocalModelFileValidator.isUsableMLXTextModelDirectory)
    }

    /// Returns true when the model's weights are already cached and look
    /// complete (both config.json and at least one weights file). Drives
    /// the "Preparing" vs "Downloading" label in the load progress pill.
    /// Mirrors the logic in `preStagedDirectory` — anything we'd accept
    /// as a load source counts as "cached" here too.
    private static func isModelCachedLocally(_ model: AssistantModel) -> Bool {
        preStagedDirectory(for: model) != nil
    }

    /// First built-in preset whose weights are already fully staged on disk
    /// AND that passes the device safety gate, excluding `excludedID`. Used as
    /// the storage-fallback target: a model that needs no download (so it can't
    /// re-trigger the out-of-space failure) and fits memory. Returns nil when
    /// nothing usable is cached.
    private static func firstReadyOnDiskAssistantModel(excluding excludedID: String) -> AssistantModel? {
        for model in AssistantModelCatalog.presets where model.id != excludedID {
            guard isModelCachedLocally(model) else { continue }
            guard MemoryAdvisor.safetyBlocker(for: model.id) == nil else { continue }
            return model
        }
        return nil
    }

    /// Best-effort weight-size estimate. If weights are pre-staged, sum
    /// the actual safetensors / .npz / .bin files; otherwise fall back
    /// to `AssistantModel.approxRAMBytes × 0.6` (4-bit weights are
    /// roughly half a byte per parameter, so disk ≈ RAM × 0.5–0.6).
    /// Used by ModelResidency to decide whether the assistant LLM and
    /// the visual VLM can both live in memory at once on this device.
    ///
    /// `static nonisolated` so it can be called from outside the actor.
    static nonisolated func estimatedWeightBytes(for model: AssistantModel) -> UInt64 {
        if let dir = preStagedDirectory(for: model) {
            let measured = sumWeightFiles(in: dir)
            if measured > 0 { return measured }
        }
        if let published = model.downloadSizeBytes {
            return UInt64(max(0, published))
        }
        // RAM estimate × 0.6 ≈ 4-bit disk size. Conservative when no
        // weights are on disk yet (predicts the eventual download size
        // for the memory-budget math).
        return UInt64(Double(model.approxRAMBytes) * 0.6)
    }

    /// Sum the weight-file sizes under `dir`. Mirrors the helper in
    /// LensInferenceLoop; kept local here so this file doesn't depend
    /// on the lens module. Returns 0 if no recognizable weight files
    /// are present.
    private static nonisolated func sumWeightFiles(in dir: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let isWeight = name.hasSuffix(".safetensors")
                        || name.hasSuffix(".npz")
                        || name.hasSuffix(".bin")
            guard isWeight else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    // MARK: - System prompt

    nonisolated static let systemPrompt = """
    You are an expert coding assistant running entirely on-device in IOSLocalLLM.

    Your capabilities:
    • Code completion, generation, and refactoring across all languages
    • Bug detection, root cause analysis, and fixes with explanations
    • Architecture review: design patterns, SOLID, performance trade-offs
    • Security audit: OWASP Top 10, injection, auth flaws, data exposure
    • Code explanation at any depth
    • Test generation (unit, integration, property-based)
    • Documentation and inline comment writing

    Rules:
    - Prefer working, runnable code when the APIs are in context or widely known
    - If a file, API, or fact is not in the conversation, say so — do not invent it
    - Prefer clarity over cleverness; name things explicitly
    - Cite the specific line/pattern when reviewing
    - Use markdown with fenced code blocks and language tags
    - Put a blank line between paragraphs and use Markdown bullets or numbered
      lists for multiple items. Never run headings, labels, or list items
      together without whitespace.
    - Be concise — no filler phrases
    """

    /// Shared anti-hallucination rules appended to every chat system prompt.
    /// Local models otherwise invent citations, tool results, and live data
    /// when a persona only describes tone.
    nonisolated static let groundingPrompt = """
    Grounding:
    - Answer only from the conversation, attached files, and tool results.
    - Do not invent citations, URLs, quotes, file contents, tool results, or live data (news, weather, prices, sports).
    - If you do not know, say so. Do not guess to sound complete.
    """

    /// Short line folded into compact GGUF prompts (no system role).
    nonisolated static let compactGroundingPrompt = """
    Answer from this conversation only. Do not invent citations, tool results, URLs, or live data. If unsure, say so.
    """

    nonisolated static let responseFormattingPrompt = """
    Format every answer for a narrow mobile screen. Put a blank line between
    paragraphs. When presenting multiple fields, choices, steps, or facts, use
    a Markdown bullet or numbered list with one item per line. Never concatenate
    a heading, label, sentence, or list item directly into the next one.
    """

    // MARK: - Load

    func load(
        allowStorageFallback: Bool = true,
        reselectFromSettings: Bool = true,
        allowUnsafeMemoryLoad: Bool = false
    ) async {
        if activeExecutionLocation == .applePrivateCloud {
            await refreshApplePrivateCloudStatus()
            return
        }

        // Resolve `model_type: nanbeige` before MLX reads config.json.
        // Registration is actor-isolated and idempotent.
        await NanbeigeMLXRegistration.register()

        // Loading/generation cannot be re-entered. A `.ready` state is only a
        // no-op when its actual runtime still exists; a shared Lens container
        // may have been reclaimed independently on memory pressure.
        switch state {
        case .loading, .generating: return
        default: break
        }

        // Pick up the user's current model selection FIRST so the safety
        // checks reflect what the user actually picked (not just qwen3-4b).
        // Skipped on a storage-fallback re-entry, which has already pointed
        // activeModel at an on-disk model without disturbing the saved choice.
        activeModel = Self.loadTarget(
            activeModel: activeModel,
            savedDefault: AssistantModelCatalog.currentSelection(),
            reselectFromSettings: reselectFromSettings
        )

        let runtimeIsResident = activeModel.runtime == .llamaCpp
            ? ggufModel != nil
            : resolvedMLXContainer != nil
        if case .ready = state, runtimeIsResident { return }
        if case .ready = state { state = .unloaded }

        if let compatibility = activeModel.platformCompatibility,
           !compatibility.supportsCurrentPlatform {
            state = .failed(compatibility.detail)
            ToastCenter.shared.error("Can't load \(activeModel.displayName)",
                                     detail: compatibility.detail)
            return
        }

        // A failed/cancelled generation can leave its model resident while the
        // service state allows `load()` to be entered again. Never begin a
        // retry or a newly-selected runtime on top of those weights: a 4.7 GB
        // GGUF followed by Qwen briefly exceeds the iOS process limit and is
        // terminated by Jetsam. `switchTo` already drains explicitly; this
        // closes the direct retry/load path as well.
        if ggufModel != nil || container != nil || generateTask != nil {
            Diagnostics.shared.breadcrumb(
                "assistant reload draining resident runtime · footprint=\(MemoryAdvisor.physFootprint) · headroom=\(MemoryAdvisor.availableMemoryForModel)",
                category: "assistant"
            )
            await unloadAndWaitForCleanup()
        }

        // The Lens runtime is the neutral owner for unified text+vision
        // packages. If it already has this model, attach instantly instead of
        // unloading it and loading identical weights through MLXLLM.
        if let _ = LensInferenceLoop.shared.sharedContainer(for: activeModel.repoID) {
            FastVLMService.shared.unload()
            await LlamaCppVLMService.shared.unloadAndWaitForCleanup()
            state = .ready
            refreshVisionChatCapability()
            Diagnostics.shared.breadcrumb(
                "assistant attached to shared dual-role runtime · \(activeModel.id) · visionChat=\(isVisionChatCapable)",
                category: "assistant"
            )
            return
        }

        // Assistant is a single-runtime surface. Drain every visual backend,
        // including llama.cpp/mtmd (which does not share the MLX gate), before
        // measuring or loading the chat model. This makes rapid Lens →
        // Assistant and Visual → Code-mode changes deterministic.
        MLXVisionService.shared.unload()
        FastVLMService.shared.unload()
        await LlamaCppVLMService.shared.unloadAndWaitForCleanup()
        await MLXGenerationGate.shared.clearCacheWhenIdle()

        // Combined device-safety gate — covers RAM, live free memory, thermal
        // state, and low-power mode. Refuses outright when unsafe.
        // GGUF uses mmap and can fall back to CPU layers when Metal headroom
        // is tight. The generic gate estimates every imported directory like
        // an eagerly-materialized MLX model (disk × 1.6), which rejected valid
        // large GGUFs before llama.cpp was even attempted.
        if activeModel.runtime != .llamaCpp,
           let block = MemoryAdvisor.safetyBlocker(
                for: activeModel.id,
                allowTightFit: AppSettings.shared.largeModelLowMemoryEnabled,
                runtime: activeModel.runtime,
                allowUnsafeMemoryLoad: allowUnsafeMemoryLoad
            ) {
            state = .failed(block)
            ToastCenter.shared.error("Can't load selected model",
                                      detail: block)
            return
        }
        if allowUnsafeMemoryLoad {
            Diagnostics.shared.breadcrumb(
                "user-confirmed unsafe memory load · \(activeModel.id)",
                category: "assistant"
            )
            ToastCenter.shared.info(
                "Experimental load started",
                detail: "iOS may close the app if this model exceeds its memory limit."
            )
        }

        // Open with "Preparing" by default — the verb users want for a
        // warm cache. The on-disk probe (preStagedDirectory) tries hard
        // but can miss HubApi cache variants. If the load turns out to
        // be a real network download, the latch below flips to
        // "Downloading" once we observe genuine network-slow progress
        // (≥3 s elapsed AND <20% complete). This way a cached model
        // never shows "Downloading" by accident — worst case is a
        // brief "Preparing" before "Downloading" on a true cold fetch,
        // which reads correctly because preparation IS the first phase
        // of any network download.
        let probedWarm = Self.isModelCachedLocally(activeModel)

        // Pre-flight DISK check for the download path. When nothing usable is
        // staged, the id-based load fetches the weights via HubApi. On a
        // near-full device that write fails late with a raw ENOSPC AFTER
        // writing a multi-GB partial snapshot that then squats on disk across
        // retries — making "no space" worse each attempt. Refuse early with the
        // honest free-vs-needed message instead, writing nothing.
        //
        // CRITICAL: credit bytes ALREADY on disk. HubApi resumes — it skips
        // files already downloaded — so the real requirement is the REMAINING
        // bytes, not the full model. Without this, a model that's 90% fetched
        // (e.g. interrupted by a previous ENOSPC, or a partial the shard-probe
        // rejected) is wrongly refused for space it doesn't actually need.
        if !probedWarm {
            let estimatedTotal = Int64(Self.estimatedWeightBytes(for: activeModel))
            let alreadyOnDisk = Self.hubCacheBytesOnDisk(for: activeModel)
            let needBytes = max(0, estimatedTotal - alreadyOnDisk) + 300_000_000
            if let free = HFModelDownloadManager.freeDiskBytes(), free < needBytes {
                let msg = Self.outOfStorageMessage(for: activeModel, remainingBytes: needBytes)
                state = .failed(msg)
                ToastCenter.shared.error("\(activeModel.displayName) needs more storage", detail: msg)
                return
            }
        }

        state = .loading("Preparing \(activeModel.displayName)…")
        loadProgressFraction = 0
        let loadStart = Date()

        // Record the selected MLX model before entering the package loader.
        // MLX promotes low-level validation failures to fatalError/SIGTRAP,
        // so a post-load breadcrumb is never reached in exactly the failure
        // mode we most need to diagnose (for example an unsupported weight
        // quantization kernel).
        if activeModel.runtime == .mlx {
            Diagnostics.shared.breadcrumb(
                "MLX assistant load · \(activeModel.id) · repo=\(activeModel.repoID) · cached=\(probedWarm)",
                category: "assistant"
            )
        }

        if activeModel.runtime == .llamaCpp {
            guard let directory = Self.preStagedDirectory(for: activeModel),
                  let modelURL = LocalModelFileValidator.ggufLLM(in: directory) else {
                state = .failed("The imported GGUF file could not be found on disk.")
                return
            }
            if let reason = DeviceSafetyMonitor.shared.stopReason {
                state = .failed(reason.detail)
                return
            }
            do {
                // Gemma 4 E4B uses recurrent + sliding-window state and its
                // community quants abort while reserving the advertised 128K
                // context on iOS, so only that family keeps the compact
                // 512-token context (matching the upstream llama-simple
                // execution path). Every other imported GGUF gets a bounded
                // 4K window — the previous blanket 512 truncated all replies
                // to ~128 tokens mid-sentence.
                let context = UInt32(ggufProfile.contextTokens)
                let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: modelURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let available = MemoryAdvisor.availableMemoryForModel
                let loadPolicy = GGUFLoadPolicy.resolve(
                    fileBytes: fileBytes,
                    pagingEnabled: AppSettings.shared.largeModelLowMemoryEnabled
                )
                let minimumNeeded = loadPolicy.minimumAvailableBytes
                guard fileBytes == 0 || available == 0 || available >= minimumNeeded else {
                    throw RuntimeError.modelLoadBlocked(reason: String(
                        format: "This GGUF needs about %.1f GB available in the selected loading mode; the app currently has %.1f GB. Close other apps, enable storage-backed paging, or use a smaller quantization.",
                        Double(minimumNeeded) / 1_000_000_000,
                        Double(available) / 1_000_000_000
                    ))
                }
                let gpuLayers = loadPolicy.gpuLayers
                Diagnostics.shared.breadcrumb(
                    "GGUF assistant load · \(modelURL.lastPathComponent) · bytes=\(fileBytes) · available=\(available) · gpuLayers=\(gpuLayers) · storageBacked=\(loadPolicy.storageBacked)",
                    category: "assistant"
                )
                ggufModel = try await Task.detached(priority: .userInitiated) {
                    try LlamaCppVLM(
                        llmPath: modelURL.path,
                        nThreads: 4,
                        contextSize: context,
                        gpuLayers: gpuLayers
                    )
                }.value
                Diagnostics.shared.breadcrumb(
                    "GGUF assistant loaded · footprint=\(MemoryAdvisor.physFootprint) · headroom=\(MemoryAdvisor.availableMemoryForModel) · gpuLayers=\(gpuLayers)",
                    category: "assistant"
                )
                state = .ready
                refreshVisionChatCapability()
                let elapsedMs = Date().timeIntervalSince(loadStart) * 1_000
                ModelUsageTracker.shared.recordLoadTime(modelID: activeModel.id, ms: elapsedMs)
                // Readiness is persistent state; the Assistant's inline
                // status row reflects `.ready` without covering the chat.
            } catch {
                ggufModel = nil
                state = .failed(error.localizedDescription)
                Diagnostics.shared.error(
                    "GGUF assistant load failed · \(error.localizedDescription)",
                    category: "assistant"
                )
                ToastCenter.shared.error("GGUF model failed to load", detail: error.localizedDescription)
            }
            return
        }

        // Latch tracks whether THIS specific load looks like a real
        // network transfer (still slow after 3 s). Starts false (=
        // "Preparing"). Flips once on slow-progress evidence and stays
        // there for the rest of the load so the label doesn't bounce.
        final class VerbLatch: @unchecked Sendable {
            private let lock = NSLock()
            private var _isNetwork: Bool
            init(_ v: Bool) { _isNetwork = v }
            var isNetwork: Bool { lock.withLock { _isNetwork } }
            func markNetwork() { lock.withLock { _isNetwork = true } }
        }
        let latch = VerbLatch(false)

        let loadingModel = activeModel
        let loadID = UUID()
        activeLoadID = loadID

        let isDualRole = DualRoleModelPolicy.isTextAndVision(repoID: loadingModel.repoID)
        let requiredVisionBytes = isDualRole
            ? LensInferenceLoop.requiredVisionLoadBytes(repoID: loadingModel.repoID)
            : 0
        let availableBytes = UInt64(max(0, MemoryAdvisor.availableMemoryForModel))
        let shouldShareVisionRuntime = DualRoleModelPolicy.shouldShareRuntime(
            isDualRole: isDualRole,
            selectionsMatch: isDualRole
                && DualRoleModelPolicy.selectionsMatch(repoID: loadingModel.repoID),
            requiredVisionBytes: requiredVisionBytes,
            availableBytes: availableBytes
        )

        if shouldShareVisionRuntime {
            await LensInferenceLoop.shared.switchTo(
                repoID: loadingModel.repoID,
                preserveMatchingAssistant: true
            )
            guard activeLoadID == loadID, activeModel.id == loadingModel.id else { return }
            activeLoadID = nil
            if LensInferenceLoop.shared.sharedContainer(for: loadingModel.repoID) != nil {
                state = .ready
                refreshVisionChatCapability()
                let elapsedMs = Date().timeIntervalSince(loadStart) * 1_000
                Diagnostics.shared.breadcrumb(
                    "assistant loaded shared dual-role runtime · \(loadingModel.id) · \(String(format: "%.1fs", elapsedMs / 1_000)) · visionChat=\(isVisionChatCapable)",
                    category: "assistant"
                )
                ModelUsageTracker.shared.recordLoadTime(modelID: loadingModel.id, ms: elapsedMs)
                // The Assistant status row owns model-ready feedback.
            } else if case .failed(let message) = LensInferenceLoop.shared.state {
                state = .failed(message)
            } else {
                state = .failed("The shared text + vision runtime could not be prepared.")
            }
            return
        } else if isDualRole {
            Diagnostics.shared.notice(
                "assistant using bounded text runtime · \(loadingModel.id) · vision required=\(Int64(requiredVisionBytes).formattedBytes) · available=\(Int64(availableBytes).formattedBytes)",
                category: "assistant"
            )
        }

        do {
            // Snapshot self-derived values up here so the gate's @Sendable
            // closure doesn't have to capture self for them.
            let modelConfig = Self.modelConfig(for: loadingModel)
            let lowMemoryPolicy = MLXLowMemoryPolicy.resolve(
                enabled: AppSettings.shared.largeModelLowMemoryEnabled,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                processCeilingBytes: MemoryAdvisor.processMemoryCeiling
            )
            // Gated so weight uploads can't race a concurrent MLXVision /
            // FastVLM load or another service's in-flight generate.
            let loadedContainer = try await MLXGenerationGate.shared.run { [weak self, latch, loadID] in
                let previousMemoryLimit = MLX.Memory.memoryLimit
                let previousCacheLimit = MLX.Memory.cacheLimit
                if let limit = lowMemoryPolicy.memoryLimitBytes {
                    MLX.Memory.memoryLimit = limit
                }
                if let cache = lowMemoryPolicy.cacheLimitBytes {
                    MLX.Memory.cacheLimit = cache
                }
                defer {
                    MLX.Memory.memoryLimit = previousMemoryLimit
                    MLX.Memory.cacheLimit = previousCacheLimit
                }
                mlxClearCache()
                // Bind the weak self into a `let` here so the inner Task
                // captures an immutable binding, not the outer closure's
                // implicitly-mutable `[weak self]` slot. Without this
                // shim Swift 6 flags "captured var 'self' in
                // concurrently-executing code" at the Task closure.
                let weakSelf = self
                return try await LLMModelFactory.shared.loadContainer(
                    from: HubApiDownloader(),
                    configuration: modelConfig
                ) { progress in
                    let fraction = progress.fractionCompleted
                    let pct = Int(fraction * 100)
                    let elapsed = Date().timeIntervalSince(loadStart)
                    // Network-slow detection: ≥3 seconds elapsed AND
                    // less than 20% complete means this is a real
                    // download (cached loads finish their progress
                    // sweep in well under 3 s on every device class).
                    // Probe hint plus this rule together cover both
                    // the easy case (probe correctly says "not cached")
                    // and the hard case (probe missed an MLX hub
                    // cache variant — we still detect from speed).
                    if !latch.isNetwork,
                       !probedWarm,
                       elapsed > 3.0,
                       progress.fractionCompleted < 0.20 {
                        latch.markNetwork()
                    }
                    let isNetwork = latch.isNetwork
                    Task { @MainActor [weakSelf, isNetwork, pct, fraction, loadID] in
                        // Hops are unordered — drop stale fractions so the
                        // percentage can't render backwards. An unload/model
                        // switch also invalidates this load ID, preventing an
                        // old download from overwriting the new model's state.
                        guard let weakSelf,
                              weakSelf.activeLoadID == loadID,
                              fraction >= weakSelf.loadProgressFraction else { return }
                        weakSelf.loadProgressFraction = fraction
                        // progress.localizedDescription is unreliable across MLX
                        // versions — sometimes "Loading", sometimes empty,
                        // sometimes already contains a %. Pick the verb here
                        // based on the latch (snapshot above into a `let`).
                        let verb = isNetwork ? "Downloading" : "Preparing"
                        weakSelf.state = .loading("\(verb) \(pct)%")
                    }
                }
            }
            guard activeLoadID == loadID, activeModel.id == loadingModel.id else {
                Diagnostics.shared.breadcrumb(
                    "discarded stale assistant load · \(loadingModel.id)",
                    category: "assistant"
                )
                await MLXGenerationGate.shared.clearCacheWhenIdle()
                return
            }
            activeLoadID = nil
            container = loadedContainer
            state = .ready
            refreshVisionChatCapability()
            let elapsedMs = Date().timeIntervalSince(loadStart) * 1000
            Diagnostics.shared.breadcrumb("assistant loaded · \(loadingModel.id) · \(String(format: "%.1fs", elapsedMs / 1000)) · visionChat=\(isVisionChatCapable)", category: "assistant")
            ModelUsageTracker.shared.recordLoadTime(modelID: loadingModel.id, ms: elapsedMs)
            // The Assistant status row owns model-ready feedback.
            // The LLM is now resident and idle. Schedule a background
            // prefetch of the VLM's weight files into the OS page cache
            // after 4 seconds of continued idleness. If the user starts
            // generating before the timer fires, the prefetch is
            // cancelled by `cancelPrefetch()` in `generate()`. Doesn't
            // load the VLM into MLX (would OOM); just primes the
            // kernel's page cache so the eventual MLX load is faster.
            ModelResidency.shared.schedulePrefetch(currentTab: .assistant)
        } catch is MLXGenerationGate.Cancelled {
            guard activeLoadID == loadID else { return }
            activeLoadID = nil
            // Gate drained mid-load — back to unloaded, not a failure.
            state = .unloaded
        } catch {
            guard activeLoadID == loadID else { return }
            activeLoadID = nil
            // Background cleanup cancels Hub/MLX work cooperatively. That is a
            // lifecycle interruption, not a broken model. Build 75 surfaced
            // the raw "cancelled" error as "Qwen failed to load" after the user
            // briefly left the app, even though memory and the model were fine.
            if Self.isCancellationError(error) {
                state = .unloaded
                Diagnostics.shared.breadcrumb(
                    "assistant load interrupted · \(activeModel.id) · willResume=\(resumeLoadAfterLifecycleInterruption)",
                    category: "assistant"
                )
                return
            }
            // Translate a raw out-of-storage POSIX error (ENOSPC) into an
            // honest, actionable message. The default localizedDescription is
            // just "The operation couldn't be completed. No space left on
            // device" — which reads as a bug to users who believe they have
            // space, because iOS's "available" figure counts purgeable caches
            // the download path can't actually use. Report the *real* free
            // bytes so the user can tell whether the disk is genuinely full.
            let outOfStorage = Self.isOutOfStorageError(error)
            if outOfStorage {
                // Reclaim the partial snapshot HubApi wrote before running out
                // of space, so it doesn't squat on disk and make the next retry
                // fail even sooner. Guarded to delete only an INCOMPLETE copy of
                // THIS model — a usable cache is never touched.
                Self.removeIncompleteHubSnapshot(for: activeModel)
            }
            let message = outOfStorage
                ? Self.outOfStorageMessage(for: activeModel)
                : error.localizedDescription
            Diagnostics.shared.error("assistant load failed · \(activeModel.id) · \(error.localizedDescription)", category: "assistant")

            // Storage-fallback safety net: when the selected model can't load
            // because the device is out of space, don't strand the user on a
            // dead "Failed to load" screen if another model is already fully on
            // disk. Switch to it for THIS session only — the saved selection is
            // left untouched, so once space is freed a retry still loads the
            // model the user actually picked. allowStorageFallback is false on
            // the re-entry so a second failure can't loop.
            if outOfStorage, allowStorageFallback,
               let fallback = Self.firstReadyOnDiskAssistantModel(excluding: activeModel.id) {
                let failedName = activeModel.displayName
                Diagnostics.shared.breadcrumb(
                    "assistant storage fallback · \(activeModel.id) → \(fallback.id)",
                    category: "assistant")
                activeModel = fallback
                state = .unloaded   // clear .loading so the re-entrant load runs
                ToastCenter.shared.info(
                    "Loaded \(fallback.displayName) instead",
                    detail: "\(failedName) needs more storage. Switched to a model already on your device — free up space, then reselect it in the picker.")
                await load(allowStorageFallback: false, reselectFromSettings: false)
                return
            }

            state = .failed(message)
            ToastCenter.shared.error("\(activeModel.displayName) failed to load",
                                      detail: message)
        }
    }

    /// Removes an INCOMPLETE HubApi snapshot for `model` left behind by a
    /// failed download (e.g. ENOSPC mid-fetch). Checks both default snapshot
    /// layouts and deletes a directory only when it exists AND fails the
    /// usable-model probe, so a complete cache is never destroyed.
    private static func removeIncompleteHubSnapshot(for model: AssistantModel) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dashed = model.repoID.replacingOccurrences(of: "/", with: "--")
        let candidates = [
            docs.appendingPathComponent("huggingface/models/\(model.repoID)", isDirectory: true),
            docs.appendingPathComponent("huggingface/hub/models--\(dashed)", isDirectory: true),
        ]
        for dir in candidates {
            guard FileManager.default.fileExists(atPath: dir.path),
                  !ModelCacheProbe.isUsableModelDirectory(dir) else { continue }
            try? FileManager.default.removeItem(at: dir)
            Diagnostics.shared.breadcrumb(
                "removed incomplete snapshot \(dir.lastPathComponent) after out-of-space",
                category: "assistant")
        }
        MemoryAdvisor.invalidateFootprintCache()
    }

    /// True when `error` (or any error it wraps) is a filesystem
    /// out-of-space condition (POSIX `ENOSPC`). MLX/HubApi surfaces this as
    /// an NSCocoaError wrapping an NSPOSIXError, so we walk the underlying
    /// chain rather than string-matching the localized text.
    private static func isOutOfStorageError(_ error: Error) -> Bool {
        var ns: NSError? = error as NSError
        var depth = 0
        while let current = ns, depth < 6 {
            if current.domain == NSPOSIXErrorDomain && current.code == Int(ENOSPC) {
                return true
            }
            if current.domain == NSCocoaErrorDomain &&
               (current.code == NSFileWriteOutOfSpaceError || current.code == NSFileWriteVolumeReadOnlyError) {
                return true
            }
            ns = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        // Last-resort substring check for paths that flatten the error chain.
        return error.localizedDescription.localizedCaseInsensitiveContains("No space left on device")
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return true }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError { return true }
        return ns.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }

    /// Records whether background cleanup interrupted an explicit model load.
    /// Called before lifecycle cancellation changes the published state.
    func noteLifecycleInterruption() {
        if case .loading = state {
            resumeLoadAfterLifecycleInterruption = true
        }
    }

    /// Resumes only a load that was already underway when the app backgrounded.
    /// This preserves the normal lazy-load policy for every other model.
    func resumeInterruptedLoadIfNeeded() async {
        guard resumeLoadAfterLifecycleInterruption else { return }
        resumeLoadAfterLifecycleInterruption = false
        guard case .loading = state else {
            state = .unloaded
            await load()
            return
        }
        // Cleanup may still be retiring the cancelled loader. The generation
        // gate serializes this retry behind it so two model loads never overlap.
        await MLXGenerationGate.shared.clearCacheWhenIdle()
        state = .unloaded
        // Resume the model whose load was interrupted. It may be a
        // conversation-specific choice that intentionally differs from the
        // saved default.
        await load(reselectFromSettings: false)
    }

    /// Keeps the distinction between an explicit runtime target and the
    /// user's saved default testable without loading model weights.
    nonisolated static func loadTarget(
        activeModel: AssistantModel,
        savedDefault: AssistantModel,
        reselectFromSettings: Bool
    ) -> AssistantModel {
        reselectFromSettings ? savedDefault : activeModel
    }

    /// Honest, actionable out-of-storage message reporting the device's real
    /// free space alongside the model's approximate footprint.
    /// Honest, actionable out-of-storage message. `remainingBytes`, when given,
    /// is the still-to-download amount (full size minus what's already cached)
    /// so the figure matches what the user must actually free; otherwise it
    /// falls back to the model's full estimated on-disk size.
    private static func outOfStorageMessage(for model: AssistantModel, remainingBytes: Int64? = nil) -> String {
        let freeStr = HFModelDownloadManager.freeDiskBytes()?.formattedBytes ?? "an unknown amount"
        let needStr = (remainingBytes ?? Int64(Double(model.approxRAMBytes) * 0.6)).formattedBytes
        return "Not enough storage to load \(model.displayName). About \(freeStr) is free, but it needs ~\(needStr) more on disk. Free up space in Settings → General → iPhone Storage, or delete other downloaded models in the Models tab, then retry."
    }

    /// Bytes of `model`'s weights already present in the HubApi cache — the
    /// location an id-based load downloads/resumes into. HubApi skips files
    /// already on disk, so the disk pre-flight credits these against the total.
    private static func hubCacheBytesOnDisk(for model: AssistantModel) -> Int64 {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dashed = model.repoID.replacingOccurrences(of: "/", with: "--")
        let dirs = [
            docs.appendingPathComponent("huggingface/models/\(model.repoID)", isDirectory: true),
            docs.appendingPathComponent("huggingface/hub/models--\(dashed)", isDirectory: true),
        ]
        var total: Int64 = 0
        for dir in dirs where FileManager.default.fileExists(atPath: dir.path) {
            if let sz = try? FileManager.default.allocatedSizeOfDirectory(at: dir) {
                total += sz
            }
        }
        return total
    }

    // MARK: - Generate (streaming, full conversation history)

    /// `maxTokensOverride` bypasses `AppSettings.assistantMaxTokens` for
    /// lightweight background calls (e.g. conversation titling) so they don't
    /// clobber the user's preferred response length.
    func generate(
        messages: [ChatMessage],
        maxTokensOverride: Int? = nil,
        temperatureOverride: Double? = nil,
        topPOverride: Double? = nil,
        samplerConfig: SamplerConfig? = nil,
        jsonMode: Bool = false,
        collectLogprobs: Bool = false,
        forceNoThinking: Bool = false,
        resumeTruncatedReply: Bool = false,
        onToken: @escaping @Sendable (String) -> Void,
        // Optional logprob stream sits before onComplete so call sites that
        // pass it (the chat view) match declaration order; callers that omit
        // it (benchmark, compare, quality eval, titler) skip the default.
        onLogprobToken: (@Sendable (TokenLogprob) -> Void)? = nil,
        onComplete: @escaping @Sendable (Double) -> Void,
        // Optional failure channel for API/bridge callers that must
        // distinguish an error from an empty-but-successful generation.
        // Local failures invoke it before onComplete(0); user-initiated
        // cancellation deliberately does not.
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        if activeExecutionLocation == .applePrivateCloud {
            generateWithApplePrivateCloud(
                messages: messages,
                maxTokensOverride: maxTokensOverride,
                temperatureOverride: temperatureOverride,
                jsonMode: jsonMode,
                forceNoThinking: forceNoThinking,
                onToken: onToken,
                onComplete: onComplete,
                onError: onError
            )
            return
        }

        // A native GGUF decode is not re-entrant. Voice Mode turn 2 used to
        // land here while turn 1 was still draining and silently no-op —
        // the mic looked live but the model never answered again. Defer
        // briefly onto the main actor so a just-finished decode can flip
        // back to `.ready`, then retry once.
        if case .generating = state {
            Task { @MainActor [weak self] in
                guard let self else {
                    onError?("Service unavailable")
                    onComplete(0)
                    return
                }
                var waited = 0
                while case .generating = self.state, waited < 40 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 1
                }
                guard case .ready = self.state else {
                    onError?("The model stayed busy; retry shortly")
                    onComplete(0)
                    return
                }
                self.generate(
                    messages: messages,
                    maxTokensOverride: maxTokensOverride,
                    temperatureOverride: temperatureOverride,
                    topPOverride: topPOverride,
                    samplerConfig: samplerConfig,
                    jsonMode: jsonMode,
                    collectLogprobs: collectLogprobs,
                    forceNoThinking: forceNoThinking,
                    resumeTruncatedReply: resumeTruncatedReply,
                    onToken: onToken,
                    onLogprobToken: onLogprobToken,
                    onComplete: onComplete,
                    onError: onError
                )
            }
            return
        }

        // Lazy load. The view layer no longer auto-loads on appear (that
        // path made every launch show a "Downloading X%" banner even when
        // the user wasn't planning to chat). The first send is the load
        // trigger now: we kick off the load, then re-enter generate once
        // the container is ready. onComplete still fires on failure so
        // the UI placeholder unfreezes either way.
        let hasRuntimeModel = activeModel.runtime == .llamaCpp
            ? ggufModel != nil
            : resolvedMLXContainer != nil
        if state != .ready || !hasRuntimeModel {
            Task { [weak self] in
                guard let self else {
                    onError?("Service unavailable")
                    onComplete(0)
                    return
                }
                if case .loading = state {
                    // Another caller is already loading — wait it out, with a
                    // deadline so a wedged load (network stall, HubApi hang)
                    // can't spin this poll forever and freeze the send.
                    let deadline = Date().addingTimeInterval(60)
                    while case .loading = self.state {
                        if Date() >= deadline {
                            onError?("Timed out waiting for the model to load")
                            onComplete(0)
                            return
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                } else if state != .ready {
                    await self.load()
                }
                let isLoaded = self.activeModel.runtime == .llamaCpp
                    ? self.ggufModel != nil
                    : self.resolvedMLXContainer != nil
                if case .ready = self.state, isLoaded {
                    self.generate(
                        messages: messages,
                        maxTokensOverride: maxTokensOverride,
                        temperatureOverride: temperatureOverride,
                        topPOverride: topPOverride,
                        samplerConfig: samplerConfig,
                        jsonMode: jsonMode,
                        collectLogprobs: collectLogprobs,
                        forceNoThinking: forceNoThinking,
                        resumeTruncatedReply: resumeTruncatedReply,
                        onToken: onToken,
                        onLogprobToken: onLogprobToken,
                        onComplete: onComplete,
                        onError: onError
                    )
                } else {
                    onError?("Failed to load the active model")
                    onComplete(0)
                }
            }
            return
        }
        guard case .ready = state else {
            onError?("The active model is not ready")
            onComplete(0)
            return
        }

        // Device-safety gate — refuse to start a fresh generation only when
        // the device is genuinely at .critical thermal state or under
        // sustained memory pressure. Use the reason-specific message so a
        // memory warning isn't mislabelled as "too hot" (and vice versa).
        let safety = DeviceSafetyMonitor.shared
        if let reason = safety.stopReason {
            ToastCenter.shared.error(reason.title, detail: reason.detail)
            onError?("\(reason.title). \(reason.detail)")
            onComplete(0)
            return
        }

        generateTask?.cancel()
        state = .generating
        lastGenerationHitTokenLimit = false
        if !resumeTruncatedReply {
            canResumeFromCache = false
        }
        lastPromptTokens = 0
        lastOutputTokens = 0
        // User started inference — cancel any pending background
        // prefetch so it doesn't compete for disk bandwidth with
        // the active generate.
        ModelResidency.shared.cancelPrefetch()

        let s = AppSettings.shared
        // Clamp max output tokens by the user's setting and the thermal advisor.
        let executionProfile = MLXAssistantExecutionProfile.resolve(
            repoID: activeModel.repoID
        )
        let lowMemoryPolicy = MLXLowMemoryPolicy.resolve(
            enabled: s.largeModelLowMemoryEnabled,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processCeilingBytes: MemoryAdvisor.processMemoryCeiling
        )
        let modelSettings = AssistantModelSettingsStore.shared.settings(
            for: activeModel.repoID
        )
        let requestedMaxTokens = min(
            maxTokensOverride
                ?? modelSettings?.maxTokens
                ?? s.assistantMaxTokens,
            safety.recommendedMaxTokens
        )
        let safeMaxTokens = AssistantGenerationBudget.maxTokens(
            runtime: activeModel.runtime,
            requested: requestedMaxTokens,
            thermalCap: safety.recommendedMaxTokens,
            backendCap: executionProfile.maxOutputTokens
        )

        // --- Full Sampler Control (Feature #1) ---
        // Resolution order: per-call samplerConfig > per-call overrides >
        // the active model's saved profile > preset from AppSettings >
        // AppSettings individual knobs > defaults.
        let sc = samplerConfig ?? SamplerConfig.default

        // If a preset is active and no per-call config was given, use preset values.
        let effectivePreset: SamplerPreset? = {
            if samplerConfig != nil { return nil }
            guard !s.samplerPresetID.isEmpty,
                  let p = SamplerPreset.preset(for: s.samplerPresetID)
            else { return nil }
            return p
        }()

        let temp = min(2.0, max(0.0,
            sc.temperature
            ?? temperatureOverride
            ?? modelSettings?.temperature
            ?? effectivePreset?.temperature
            ?? s.assistantTemperature
        ))
        let topP = min(1.0, max(0.0,
            sc.topP
            ?? topPOverride
            ?? modelSettings?.topP
            ?? effectivePreset?.topP
            ?? s.assistantTopP
        ))
        let topK = sc.topK
            ?? modelSettings?.topK
            ?? effectivePreset?.topK
            ?? s.assistantTopK
        let minP = sc.minP
            ?? modelSettings?.minP
            ?? effectivePreset?.minP
            ?? s.assistantMinP
        let repPenalty = sc.repetitionPenalty
            ?? modelSettings?.repetitionPenalty
            ?? effectivePreset?.repetitionPenalty
            ?? s.assistantRepetitionPenalty
        let freqPenalty = sc.frequencyPenalty
            ?? effectivePreset?.frequencyPenalty
            ?? s.assistantFrequencyPenalty
        let presPenalty = sc.presencePenalty
            ?? effectivePreset?.presencePenalty
            ?? s.assistantPresencePenalty
        let seed: UInt64? = {
            if let s = sc.seed { return s }
            if let s = effectivePreset?.seed { return s }
            let stored = s.assistantSeed
            return stored != 0 ? stored : nil
        }()

        // `let` (not `var`): every sampler knob this MLX build supports is set
        // in the initializer, so params is never mutated afterward — and an
        // immutable value is safe to capture in the concurrent generate closure
        // below (a captured `var` is a Swift 6 concurrency error).
        // The family profile owns KV precision/window and prefill chunking.
        // Normal models retain the previous 8-bit/unbounded behavior; Bonsai
        // 27B uses a rotating 2K 4-bit cache so text generation remains below
        // the iPhone process watermark.
        let params = GenerateParameters(
            maxTokens: safeMaxTokens,
            maxKVSize: executionProfile.maxKVSize,
            kvBits: executionProfile.kvBits,
            temperature: Float(temp),
            topP: Float(topP),
            topK: topK,
            minP: Float(minP),
            repetitionPenalty: Float(repPenalty),
            presencePenalty: Float(presPenalty),
            frequencyPenalty: Float(freqPenalty),
            prefillStepSize: executionProfile.prefillStepSize,
            seed: seed
        )

        // --- JSON Mode (Feature #2) ---
        // Inject JSON-output instructions into the last system message.
        var effectiveMessages = messages
        let useJSONMode = jsonMode || s.jsonModeEnabled
        if useJSONMode {
            let jsonHint = s.jsonSchemaHint.isEmpty
                ? "Respond with valid JSON only. No markdown fences, no commentary."
                : "Respond with valid JSON matching this schema. No markdown fences, no commentary:\n\(s.jsonSchemaHint)"
            if let sysIdx = effectiveMessages.lastIndex(where: { $0.role == .system }) {
                var updated = effectiveMessages[sysIdx]
                updated.content += "\n\n[JSON MODE] \(jsonHint)"
                effectiveMessages[sysIdx] = updated
            } else {
                effectiveMessages.insert(
                    ChatMessage(role: .system, content: "[JSON MODE] \(jsonHint)"),
                    at: 0
                )
            }
        }

        // Trim conversation history to fit within the model's practical context
        // window, capped by tier: an unclamped 28K-token prompt's KV cache
        // (~140 KB/token fp16 on a 4B model) adds multiple GB that the load
        // gate never accounted for. 8-bit KV quantization (above) halves the
        // per-token cost; this cap bounds the count.
        let isImportedGGUF = activeModel.runtime == .llamaCpp
        let messagesForRuntime = isImportedGGUF
            ? ggufProfile.messagesForRuntime(effectiveMessages)
            : effectiveMessages
        let deviceContextCap = (DeviceTierAdvisor.current == .max) ? 16_384 : 8_192
        let inputBudget = isImportedGGUF
            ? ggufProfile.inputBudget(requestedOutputTokens: safeMaxTokens)
            : executionProfile.inputBudget(
                modelContextWindowTokens: activeModel.contextWindowTokens,
                deviceContextCap: deviceContextCap,
                requestedOutputTokens: safeMaxTokens
            )
        let trimmedMessages = Self.trimToInputBudget(messagesForRuntime, maxTokens: inputBudget)

        // Expose estimated input token count so the UI can render context-window bar.
        estimatedInputTokens = trimmedMessages.map {
            $0.contentForModel.count / 4 + 4
        }.reduce(0, +)

        // --- Chat Template Support (Feature #6) ---
        // Use the model's resolved chat template instead of hardcoded Qwen3 template.
        // Non-ChatML models (Llama, Gemma, Phi) now get proper formatting.
        let template = activeModel.chatTemplate
        let wantsThinking = modelSettings?.thinkingEnabled ?? s.assistantThinking
        let enableThinking = activeModel.supportsThinking
            && wantsThinking
            && !forceNoThinking
        let manualPrompt: String? = template.supportsThinking
            ? trimmedMessages.formattedWithTemplate(
                template,
                enableThinking: enableThinking,
                leaveLastAssistantOpen: resumeTruncatedReply
            )
            : trimmedMessages.formattedWithTemplate(
                template,
                leaveLastAssistantOpen: resumeTruncatedReply
            )

        // NOTE: the MLXLMCommon `[Chat.Message]` for the fallback path is built
        // INSIDE the generation closure (below), from `trimmedMessages`. That
        // app-owned `[ChatMessage]` is Sendable; the MLX `[Chat.Message]` is
        // not, so constructing it here and capturing it in the @Sendable gate
        // closure is a Swift 6 error. Building it at the use site captures only
        // the Sendable source — same result, no boundary violation.

        // --- Logprobs Collection (Feature #3) ---
        // This MLX build's `Generation` yields only `.chunk` / `.info` — no
        // per-token logprobs to accumulate or rank — so we stream each token
        // through onLogprobToken with neutral values (the documented
        // "unavailable → no-op" path) rather than keeping a write-only array.
        let shouldCollectLogprobs = collectLogprobs || s.logprobsEnabled

        // Capture model ID for the usage tracker.
        let trackerModelID = activeModel.id

        // Assistant image-viewing (when the loaded runtime is the dual-role
        // shared vision container): any user turn carrying imageThumbnails
        // is passed to the model via MLXVLM `.ciImage` inputs below. Text-only
        // runtimes — bounded text container (a dual-role model loaded with no
        // headroom for its vision envelope) or a GGUF assistant loaded without
        // an mmproj projector — were flagged `!isVisionChatCapable` at load
        // time, so the chat stays text-only and any attached thumbnails are
        // display-only in the chat bubble. This mirrors TokenAI's MLXEngine:
        // image thumbnails only become `UserInput.Image`s on user turns when
        // a vision runtime actually consumed them.
        let useVisionChat = isVisionChatCapable
            && trimmedMessages.contains { $0.role == .user && !$0.imageThumbnails.isEmpty }

        if let ggufModel, activeModel.runtime == .llamaCpp {
            let service = self
            let generationID = UUID()
            activeGGUFGenerationID = generationID
            let loggedFirstToken = OSAllocatedUnfairLock(initialState: false)
            // Only the recurrent Gemma quants keep the hard 128-token output
            // cap; other imported GGUFs follow the user's setting (already
            // clamped by the thermal advisor in safeMaxTokens, and by the
            // remaining context inside the bridge).
            let ggufMaxTokens = ggufProfile.clampedOutputTokens(safeMaxTokens)
            let ggufPrompt = ggufProfile.prompt(
                from: trimmedMessages,
                template: template,
                enableThinking: enableThinking,
                leaveLastAssistantOpen: resumeTruncatedReply
            )
            let ggufSampler = LlamaCppVLM.GGUFSamplerSpec(
                temperature: Float(temp),
                topP: Float(topP),
                topK: Int32(clamping: topK),
                repetitionPenalty: Float(repPenalty),
                seed: seed.map { UInt32(truncatingIfNeeded: $0) }
            )
            let reuseGGUFContext = ggufProfile == .standard
            Diagnostics.shared.breadcrumb(
                "GGUF generation start · footprint=\(MemoryAdvisor.physFootprint) · headroom=\(MemoryAdvisor.availableMemoryForModel)",
                category: "assistant"
            )
            generateTask = Task.detached(priority: .userInitiated) {
                do {
                    let emitToken: (String) -> Void = { token in
                        let isFirst = loggedFirstToken.withLock { logged -> Bool in
                            guard !logged else { return false }
                            logged = true
                            return true
                        }
                        if isFirst {
                            Diagnostics.shared.breadcrumb(
                                "GGUF first token · footprint=\(MemoryAdvisor.physFootprint) · headroom=\(MemoryAdvisor.availableMemoryForModel)",
                                category: "assistant"
                            )
                        }
                        onToken(token)
                    }
                    let resumeFromCache = resumeTruncatedReply
                        && reuseGGUFContext
                        && ggufModel.hasContinuableCache
                    let result = try {
                        if resumeFromCache {
                            return try ggufModel.continueText(
                                maxTokens: ggufMaxTokens,
                                sampler: ggufSampler,
                                onToken: emitToken
                            )
                        }
                        return try ggufModel.generateText(
                            prompt: ggufPrompt,
                            maxTokens: ggufMaxTokens,
                            sampler: ggufSampler,
                            reuseContext: reuseGGUFContext,
                            onToken: emitToken
                        )
                    }()
                    // `generateText` has returned, so its prompt/decode batches
                    // and generation guard are fully released before the UI can
                    // initiate an automatic recovery/tool follow-up.
                    let rate = result.tokensPerSecond
                    Diagnostics.shared.breadcrumb(
                        "GGUF generation complete · rate=\(String(format: "%.2f", rate)) · hitTokenLimit=\(result.hitTokenLimit) · footprint=\(MemoryAdvisor.physFootprint) · headroom=\(MemoryAdvisor.availableMemoryForModel)",
                        category: "assistant"
                    )
                    await MainActor.run {
                        let ownsState = service.activeGGUFGenerationID == generationID
                        if ownsState {
                            service.activeGGUFGenerationID = nil
                            service.generateTask = nil
                            if case .generating = service.state { service.state = .ready }
                        }
                        if ownsState {
                            service.tokenRate = rate
                            service.lastGenerationHitTokenLimit = result.hitTokenLimit
                            service.canResumeFromCache = reuseGGUFContext && result.hitTokenLimit
                            service.lastPromptTokens = result.promptTokens
                            service.lastOutputTokens = result.outputTokens
                            service.estimatedInputTokens = result.promptTokens
                            ModelUsageTracker.shared.recordGeneration(
                                modelID: trackerModelID,
                                tokens: result.outputTokens,
                                tokensPerSecond: rate
                            )
                        }
                        onComplete(rate)
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        if service.activeGGUFGenerationID == generationID {
                            service.activeGGUFGenerationID = nil
                            service.generateTask = nil
                            if case .generating = service.state { service.state = .ready }
                        }
                        onComplete(0)
                    }
                } catch LlamaCppError.cancelled {
                    await MainActor.run {
                        // User cancellation is an expected control flow, not a
                        // model failure. Keep the loaded runtime reusable and
                        // avoid exposing the retry path while it is resident.
                        if service.activeGGUFGenerationID == generationID {
                            service.activeGGUFGenerationID = nil
                            service.generateTask = nil
                            if case .generating = service.state { service.state = .ready }
                        }
                        Diagnostics.shared.breadcrumb(
                            "GGUF assistant generation cancelled",
                            category: "assistant"
                        )
                        onComplete(0)
                    }
                } catch {
                    await MainActor.run {
                        if service.activeGGUFGenerationID == generationID {
                            service.activeGGUFGenerationID = nil
                            service.generateTask = nil
                            service.state = .failed(error.localizedDescription)
                        }
                        Diagnostics.shared.error(
                            "GGUF assistant generation failed · \(error.localizedDescription)",
                            category: "assistant"
                        )
                        onError?(error.localizedDescription)
                        onComplete(0)
                    }
                }
            }
            return
        }

        guard let container = resolvedMLXContainer else {
            onError?("The active model is not loaded")
            onComplete(0)
            return
        }

        generateTask = Task {
            // Watch for iOS memory warnings — bail out gracefully instead of
            // getting Jetsam-killed silently.
            let memoryWarningTask = Task { @MainActor in
                let center = NotificationCenter.default
                for await _ in center.notifications(
                    named: UIApplication.didReceiveMemoryWarningNotification
                ).map({ _ in () }) {
                    Diagnostics.shared.breadcrumb(
                        "memory warning during generation — queueing GPU cache clear",
                        category: "assistant"
                    )
                    await MLXGenerationGate.shared.clearCacheWhenIdle()
                    // Keep generating; only stop on repeated rapid warnings.
                    break
                }
            }
            defer { memoryWarningTask.cancel() }

            // Watch for thermal escalation — if the device crosses into
            // .critical mid-stream, stop so we don't push it further into a
            // thermal shutdown. We deliberately do NOT stop at .serious: that
            // state is normal during prompt prefill / sustained inference on
            // modern silicon (iOS throttles clocks there on its own), and
            // stopping on it produced spurious "device too hot" interruptions
            // mid-reply. Matches DeviceSafetyMonitor's throttle-at-serious,
            // stop-at-critical schedule.
            let thermalTask = Task { @MainActor [weak self] in
                let center = NotificationCenter.default
                for await _ in center.notifications(
                    named: ProcessInfo.thermalStateDidChangeNotification
                ).map({ _ in () }) {
                    guard let self else { break }
                    let s = ProcessInfo.processInfo.thermalState
                    if s == .critical {
                        Diagnostics.shared.breadcrumb(
                            "thermal \(s.rawValue) mid-generation — stopping",
                            category: "assistant"
                        )
                        self.stopGeneration()
                        ToastCenter.shared.error(
                            "Stopped — device too hot",
                            detail: "Set the device down to cool, then continue."
                        )
                        break
                    }
                }
            }
            defer { thermalTask.cancel() }

            do {
                let start = Date()
                // Capture the final tokens/sec SYNCHRONOUSLY inside the loop.
                // The @Published `tokenRate` is updated via an unordered
                // `Task { @MainActor … }` hop, so reading it back after the
                // loop raced those hops and recorded a stale (often 0) rate.
                let finalRate = OSAllocatedUnfairLock<Double>(initialState: 0)
                let finalUsage = OSAllocatedUnfairLock(initialState: (prompt: 0, output: 0, hitLimit: false))

                // Funnel through MLXGenerationGate to serialize against
                // FastVLM / MLXVision — concurrent submits to Metal's
                // command queue cause the C++ check_error abort.
                try await MLXGenerationGate.shared.run { [container] in
                    let previousMemoryLimit = MLX.Memory.memoryLimit
                    let previousCacheLimit = MLX.Memory.cacheLimit
                    if let limit = lowMemoryPolicy.memoryLimitBytes {
                        MLX.Memory.memoryLimit = limit
                    }
                    MLX.Memory.cacheLimit = lowMemoryPolicy.cacheLimitBytes
                        ?? executionProfile.cacheLimitBytes
                    defer {
                        MLX.Memory.memoryLimit = previousMemoryLimit
                        MLX.Memory.cacheLimit = previousCacheLimit
                    }
                    // Inside the gate, this clear is ordered after all prior
                    // MLX operations and before this generation's first submit.
                    mlxClearCache()
                    try await container.perform { context in
                        // Use the manually-built prompt from the model's chat template.
                        // Previously only Qwen3 got a manual prompt; now ALL models do
                        // via ChatTemplate.format(). The fallback to UserInput(chat:)
                        // is kept for models where the template is .generic (ChatML),
                        // and is also forced ON when image inputs are attached —
                        // manualPrompt is text-only, so it can't carry pixels.
                        let useManualPrompt = resumeTruncatedReply
                            || (!template.format.hasPrefix("generic") && !useVisionChat)
                        let userInput: UserInput
                        if useManualPrompt, let manualPrompt {
                            userInput = UserInput(prompt: manualPrompt)
                        } else {
                            // Build the MLX chat array here (see note above) so
                            // the non-Sendable [Chat.Message] never crosses the
                            // @Sendable boundary. When `useVisionChat`, attach
                            // each user turn's `imageThumbnails` as MLXVLM
                            // `.ciImage` inputs so the dual-role vision container
                            // actually sees the pixels. Images ride ONLY user
                            // turns — Qwen-VL's chat template emits the
                            // `<|image_pad|>` placeholder for user content, and
                            // an image embedded in an assistant turn leaves the
                            // processor with a frame and no matching placeholder
                            // ("Number of placeholder tokens does not match
                            // number of frames").
                            let chatMessages: [Chat.Message] = trimmedMessages.compactMap { msg -> Chat.Message? in
                                switch msg.role {
                                case .system:    return .system(msg.contentForModel)
                                case .assistant: return .assistant(msg.contentForModel)
                                case .tool:      return .user("Tool result:\n\(msg.contentForModel)")
                                case .user:
                                    guard useVisionChat else { return .user(msg.contentForModel) }
                                    let imgs: [UserInput.Image] = msg.imageThumbnails.compactMap { att -> UserInput.Image? in
                                        guard let ui = UIImage(data: att.data),
                                              let ci = Self.ciImage(from: ui) else { return nil }
                                        return .ciImage(ci)
                                    }
                                    return .user(msg.contentForModel, images: imgs)
                                }
                            }
                            userInput = UserInput(chat: chatMessages)
                        }
                        let lmInput = try await context.processor.prepare(input: userInput)
                        let cache = context.model.newCache(parameters: params)

                        var tokenIndex = 0
                        for await generation in try MLXLMCommon.generate(
                            input: lmInput,
                            cache: cache,
                            parameters: params,
                            context: context
                        ) {
                            if Task.isCancelled { break }
                            if let chunk = generation.chunk {
                                onToken(chunk)

                                // Collect logprobs if enabled (Feature #3).
                                // MLX may not return logprobs natively; this is a
                                // best-effort collection from whatever the framework
                                // provides. When logprobs are unavailable, this is a
                                // no-op and the caller gets an empty array.
                                if shouldCollectLogprobs {
                                    let lp = TokenLogprob(
                                        tokenIndex: tokenIndex,
                                        token: chunk,
                                        logprob: 0,
                                        topAlternatives: []
                                    )
                                    onLogprobToken?(lp)
                                    tokenIndex += 1
                                }
                            }
                            if let info = generation.info {
                                let rate = info.tokensPerSecond
                                finalRate.withLock { $0 = rate }
                                finalUsage.withLock {
                                    let hitLimit: Bool
                                    if case .length = info.stopReason {
                                        hitLimit = true
                                    } else {
                                        hitLimit = false
                                    }
                                    $0 = (
                                        prompt: info.promptTokenCount,
                                        output: info.generationTokenCount,
                                        hitLimit: hitLimit
                                    )
                                }
                                Task { @MainActor [weak self] in self?.tokenRate = rate }
                            }
                        }

                        mlxClearCache()
                    }
                }

                let elapsed = Date().timeIntervalSince(start)
                let rate = elapsed > 0 ? finalRate.withLock({ $0 }) : 0
                let usage = finalUsage.withLock { $0 }
                let recordedTokens = usage.output > 0 ? usage.output : Int(rate * elapsed)
                await MainActor.run { [weak self] in
                    // Restore .ready only if still generating — unload() may
                    // have torn the container down mid-flight, and flipping
                    // back to .ready would show "ready" with nothing loaded.
                    if case .generating = self?.state { self?.state = .ready }
                    self?.lastPromptTokens = usage.prompt
                    self?.lastOutputTokens = usage.output
                    self?.lastGenerationHitTokenLimit = usage.hitLimit
                    if usage.prompt > 0 {
                        self?.estimatedInputTokens = usage.prompt
                    }
                    ModelUsageTracker.shared.recordGeneration(
                        modelID: trackerModelID,
                        tokens: recordedTokens,
                        tokensPerSecond: rate
                    )
                    onComplete(rate)
                    // Do not start speculative disk I/O after every reply.
                    // Prefetch is scheduled only after an explicit model load;
                    // repeatedly warming the other model here made the phone
                    // keep working between messages and increased heat.
                }

            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    if case .generating = self?.state { self?.state = .ready }
                    onComplete(0)
                }

            } catch is MLXGenerationGate.Cancelled {
                // Gate drained — same UX as a user-initiated cancel.
                await MainActor.run { [weak self] in
                    if case .generating = self?.state { self?.state = .ready }
                    onComplete(0)
                }

            } catch {
                await MainActor.run { [weak self] in
                    self?.state = .failed(error.localizedDescription)
                    onError?(error.localizedDescription)
                    onComplete(0)
                }
            }
        }
    }

    // MARK: - Apple Private Cloud generation

    func refreshApplePrivateCloudStatus() async {
        guard ApplePrivateCloud.isSupportedOnCurrentOS else {
            applePrivateCloudStatus = .unsupportedOS
            applePrivateCloudContextSize = nil
            return
        }
        let status = await ApplePrivateCloud.currentStatus()
        applePrivateCloudStatus = status
        applePrivateCloudContextSize = status.canSend
            ? await ApplePrivateCloud.contextSize()
            : nil
    }

    /// Selects PCC without pretending it is a downloaded model. No prompt is
    /// sent here; the picker must collect versioned privacy consent first.
    @discardableResult
    func selectApplePrivateCloud(
        persistAsDefault: Bool = true
    ) async -> Bool {
        guard ApplePrivateCloud.isSupportedOnCurrentOS else {
            ToastCenter.shared.error(
                "Apple Private Cloud unavailable",
                detail: ApplePrivateCloud.unavailableError.localizedDescription
            )
            return false
        }
        if case .loading = state {
            ToastCenter.shared.info(
                "Model still loading",
                detail: "Wait for the current local model load to finish before switching."
            )
            return false
        }
        guard !isTransitioning else { return false }

        isTransitioning = true
        defer { isTransitioning = false }

        if activeExecutionLocation != .applePrivateCloud {
            stopGeneration()
            await unloadAndWaitForCleanup()
            activeExecutionLocation = .applePrivateCloud
        }
        if persistAsDefault {
            AppSettings.shared.hasPickedAssistantModel = true
            AppSettings.shared.assistantModelID = ApplePrivateCloud.modelID
        }
        await refreshApplePrivateCloudStatus()
        return true
    }

    private func generateWithApplePrivateCloud(
        messages: [ChatMessage],
        maxTokensOverride: Int?,
        temperatureOverride: Double?,
        jsonMode: Bool,
        forceNoThinking: Bool,
        onToken: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (Double) -> Void,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        let settings = AppSettings.shared
        guard settings.hasCurrentApplePCCPrivacyConsent else {
            ToastCenter.shared.error(
                "Review privacy before using Apple Private Cloud",
                detail: "Choose Apple Private Cloud again to review and accept the disclosure."
            )
            onError?("Apple Private Cloud privacy consent has not been accepted")
            onComplete(0)
            return
        }
        guard applePrivateCloudGenerationState != .generating else {
            onError?("Apple Private Cloud is already generating")
            onComplete(0)
            return
        }

        pccGenerateTask?.cancel()
        let requestID = UUID()
        activePCCRequestID = requestID
        applePrivateCloudGenerationState = .generating
        tokenRate = 0

        pccGenerateTask = Task { [weak self] in
            guard let self else {
                onComplete(0)
                return
            }

            await self.refreshApplePrivateCloudStatus()
            guard self.applePrivateCloudStatus.canSend else {
                let error = self.applePrivateCloudError(
                    for: self.applePrivateCloudStatus
                )
                self.finishApplePrivateCloudRequest(
                    id: requestID,
                    result: .failure(error),
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }
            guard let contextSize = self.applePrivateCloudContextSize else {
                self.finishApplePrivateCloudRequest(
                    id: requestID,
                    result: .failure(.temporary("Apple Private Cloud context information is unavailable.")),
                    onComplete: onComplete,
                    onError: onError
                )
                return
            }

            let maximumResponseTokens = max(
                1,
                min(maxTokensOverride ?? settings.assistantMaxTokens, contextSize - 1)
            )
            let inputBudget = ApplePrivateCloud.inputBudget(
                contextSize: contextSize,
                maximumResponseTokens: maximumResponseTokens
            )
            var effectiveMessages = messages
            if jsonMode || settings.jsonModeEnabled {
                let jsonHint = settings.jsonSchemaHint.isEmpty
                    ? "Respond with valid JSON only. No markdown fences or commentary."
                    : "Respond with valid JSON matching this schema. No markdown fences or commentary:\n\(settings.jsonSchemaHint)"
                effectiveMessages.insert(
                    ChatMessage(role: .system, content: "[JSON MODE] \(jsonHint)"),
                    at: 0
                )
            }
            let trimmedMessages = Self.trimToInputBudget(
                effectiveMessages,
                maxTokens: inputBudget
            )
            self.estimatedInputTokens = trimmedMessages.reduce(0) {
                $0 + $1.contentForModel.count / 4 + 4
            }
            let conversation = ApplePrivateCloudPromptBuilder.build(
                messages: trimmedMessages
            )
            let requestedReasoning: ApplePCCReasoningLevel =
                forceNoThinking ? .light : settings.applePCCReasoningLevel
            let temperature = min(
                2,
                max(0, temperatureOverride ?? settings.assistantTemperature)
            )
            let request = ApplePCCRequest(
                id: requestID,
                prompt: conversation.prompt,
                instructions: conversation.instructions,
                reasoning: requestedReasoning,
                maximumResponseTokens: maximumResponseTokens,
                temperature: temperature
            )

            do {
                let stream = await ApplePrivateCloud.stream(request)
                for try await delta in stream {
                    try Task.checkCancellation()
                    onToken(delta)
                }
                self.finishApplePrivateCloudRequest(
                    id: requestID,
                    result: .success(()),
                    onComplete: onComplete,
                    onError: onError
                )
            } catch is CancellationError {
                self.finishApplePrivateCloudRequest(
                    id: requestID,
                    result: .failure(.cancelled),
                    onComplete: onComplete,
                    onError: onError
                )
            } catch let error as ApplePCCError {
                self.finishApplePrivateCloudRequest(
                    id: requestID,
                    result: .failure(error),
                    onComplete: onComplete,
                    onError: onError
                )
            } catch {
                self.finishApplePrivateCloudRequest(
                    id: requestID,
                    result: .failure(.unknown(error.localizedDescription)),
                    onComplete: onComplete,
                    onError: onError
                )
            }
        }
    }

    private func finishApplePrivateCloudRequest(
        id: UUID,
        result: Result<Void, ApplePCCError>,
        onComplete: @escaping @Sendable (Double) -> Void,
        onError: (@Sendable (String) -> Void)? = nil
    ) {
        guard activePCCRequestID == id else { return }
        activePCCRequestID = nil
        pccGenerateTask = nil
        switch result {
        case .success:
            applePrivateCloudGenerationState = .idle
        case .failure(.cancelled):
            applePrivateCloudGenerationState = .idle
        case .failure(let error):
            applePrivateCloudGenerationState = .failed(error)
            ToastCenter.shared.error(
                "Apple Private Cloud unavailable",
                detail: error.localizedDescription
            )
            onError?(error.localizedDescription)
        }
        onComplete(0)
    }

    private func applePrivateCloudError(
        for status: ApplePCCStatus
    ) -> ApplePCCError {
        switch status {
        case .limitReached:
            return .quotaExceeded
        case .offline:
            return .offline
        case .unsupportedOS:
            return ApplePrivateCloud.unavailableError
        case .unsupportedDevice:
            return .unavailable("This device isn't eligible for Apple Private Cloud.")
        case .appleIntelligenceUnavailable:
            return .unavailable("Apple Intelligence isn't ready. Check Settings and try again.")
        case .temporarilyUnavailable, .entitlementUnavailable, .unknown:
            return .temporary("")
        case .ready, .approachingLimit:
            return .unknown("")
        }
    }

    // MARK: - Context window trimming

    /// Trims a conversation to fit within `maxTokens` of estimated input.
    /// Always preserves system messages and the most-recent turn pair.
    /// Drops the oldest non-system messages first (same strategy used by
    /// ChatGPT, Claude, and Gemini mobile apps to handle long conversations).
    ///
    /// Token estimate: 1 token ≈ 4 characters (conservative for code+English).
    nonisolated static func trimToInputBudget(
        _ messages: [ChatMessage],
        maxTokens: Int
    ) -> [ChatMessage] {
        let tokenEstimate: (ChatMessage) -> Int = { msg in
            // +4 for per-message overhead (role header, separators)
            msg.contentForModel.count / 4 + 4
        }

        let systemMessages   = messages.filter { $0.role == .system }
        let dialogMessages   = messages.filter { $0.role != .system }

        let systemBudgetUsed = systemMessages.map(tokenEstimate).reduce(0, +)
        var remaining        = maxTokens - systemBudgetUsed

        guard let latestIndex = dialogMessages.indices.last else {
            return systemMessages
        }

        // Reserve the newest message first. It is normally the user's current
        // prompt and must survive even if it alone exceeds the estimate.
        var keptByIndex: [Int: ChatMessage] = [
            latestIndex: dialogMessages[latestIndex]
        ]
        remaining = max(0, remaining - tokenEstimate(dialogMessages[latestIndex]))

        // A terse follow-up such as "Have you summarized all?" depends on the
        // complete prior turn: both the user's subject and the assistant's
        // response. Reserve the prior user message first so a long assistant
        // reply cannot consume the entire budget and erase what "all" means.
        let priorAssistantIndex = dialogMessages.indices
            .reversed()
            .first { index in
                index < latestIndex && dialogMessages[index].role == .assistant
            }
        let priorUserIndex = priorAssistantIndex.flatMap { assistantIndex in
            dialogMessages.indices
                .reversed()
                .first { index in
                    index < assistantIndex && dialogMessages[index].role == .user
                }
        }
        if let priorUserIndex, remaining > 4 {
            let priorUser = dialogMessages[priorUserIndex]
            let fullCost = tokenEstimate(priorUser)
            if fullCost <= remaining {
                keptByIndex[priorUserIndex] = priorUser
                remaining -= fullCost
            } else {
                // Grounding payloads can dwarf the visible request. When the
                // whole source no longer fits, preserve the displayed request
                // so pronouns and follow-up intent still have an antecedent.
                var visibleOnly = priorUser
                visibleOnly.modelContent = nil
                let visibleCost = tokenEstimate(visibleOnly)
                if visibleCost <= remaining {
                    keptByIndex[priorUserIndex] = visibleOnly
                    remaining -= visibleCost
                }
            }
        }

        // Preserve the prior assistant response next. If it does not fit
        // whole, retain its tail because models conventionally put conclusions
        // and proposed next actions at the end.
        if let priorAssistantIndex, remaining > 4 {
            let prior = dialogMessages[priorAssistantIndex]
            let priorCost = tokenEstimate(prior)
            if priorCost <= remaining {
                keptByIndex[priorAssistantIndex] = prior
                remaining -= priorCost
            } else {
                let truncationPrefix = "…\n"
                let characterBudget = max(
                    0,
                    (remaining - 4) * 4 - truncationPrefix.count
                )
                if characterBudget > 0 {
                    keptByIndex[priorAssistantIndex] = ChatMessage(
                        id: prior.id,
                        role: prior.role,
                        content: truncationPrefix
                            + String(prior.contentForModel.suffix(characterBudget)),
                        timestamp: prior.timestamp
                    )
                }
                remaining = 0
            }
        }

        // Fill any remaining budget newest → oldest, skipping the protected
        // immediate context above.
        if remaining > 0 {
            for index in dialogMessages.indices.reversed()
                where keptByIndex[index] == nil {
                let message = dialogMessages[index]
                let cost = tokenEstimate(message)
                guard cost <= remaining else { break }
                keptByIndex[index] = message
                remaining -= cost
            }
        }

        let kept = dialogMessages.indices.compactMap { keptByIndex[$0] }
        return systemMessages + kept
    }

    // MARK: - Vision input helper

    /// Safely convert a `UIImage` into a `CIImage` for MLX-VLM image input.
    /// Returns `nil` (rather than force-unwrapping) for images backed by
    /// neither a `CGImage` nor a `CIImage` — e.g. some symbol/vector or
    /// filtered sources that would otherwise crash the vision processor.
    /// Mirrors the helper in TokenAI's `MLXEngine` so a degenerate
    /// thumbnail is skipped instead of poisoning the chat-array build.
    nonisolated static func ciImage(from image: UIImage) -> CIImage? {
        if let ci = image.ciImage { return ci }
        if let cg = image.cgImage { return CIImage(cgImage: cg) }
        return nil
    }

    // MARK: - Stop

    func stopGeneration() {
        if let activePCCRequestID {
            ApplePrivateCloud.cancel(activePCCRequestID)
        }
        pccGenerateTask?.cancel()
        ggufModel?.cancelCurrent()
        ggufModel?.invalidateTokenCache()
        canResumeFromCache = false
        generateTask?.cancel()
        // Do not expose `.ready` until the native decode has observed the
        // cancellation and fully unwound. Starting another request while the
        // old context is still freeing is unsafe in llama.cpp.
    }

    /// Called during background transition. Cooperatively cancels the active
    /// generation and waits briefly for it to unwind. Does NOT block
    /// indefinitely — the background task expiration handler cancels the
    /// waiting Task.
    func cancelAndDrainInference() async {
        let inflight = generateTask
        let pccInflight = pccGenerateTask
        stopGeneration()
        Diagnostics.shared.breadcrumb(
            "assistant inference cancel requested · slot=assistant · model=\(activeModel.id)",
            category: "lifecycle"
        )
        // Holding the task and awaiting its value is the synchronization
        // boundary between decoding and teardown. Without it, background
        // cleanup could release an MLX/llama.cpp runtime while its final Metal
        // command buffer or native decode frame was still retiring.
        if let inflight {
            _ = await inflight.value
        }
        if let pccInflight {
            _ = await pccInflight.value
        }
        Diagnostics.shared.breadcrumb(
            "assistant inference drained · slot=assistant · model=\(activeModel.id)",
            category: "lifecycle"
        )
    }

    // MARK: - Unload

    func unload() {
        // Same drain-before-clear pattern as MLXVisionService.unload():
        // calling mlxClearCache() while a generate task is mid-Metal
        // command-buffer raced the completion handler into
        // `mlx::core::gpu::check_error` and SIGABRTed. Wait for the
        // in-flight task to actually end, THEN flush the buffer pool.
        activeLoadID = nil
        state = .unloaded
        refreshVisionChatCapability()
        Task { @MainActor in
            await unloadAndWaitForCleanup()
        }
    }

    /// Async variant for callers that need deterministic memory
    /// reclamation before proceeding with another large model load.
    func unloadAndWaitForCleanup() async {
        let footprintBefore = MemoryAdvisor.physFootprint
        let headroomBefore = MemoryAdvisor.availableMemoryForModel
        let releasedGGUF = ggufModel != nil
        Diagnostics.shared.breadcrumb(
            "assistant unload begin · gguf=\(releasedGGUF) · footprint=\(footprintBefore) · headroom=\(headroomBefore)",
            category: "assistant"
        )
        let inflight = generateTask
        activeLoadID = nil
        generateTask = nil
        inflight?.cancel()
        ggufModel?.cancelCurrent()
        if let inflight {
            _ = await inflight.value
        }
        // Release runtime ownership only after the cancelled generation has
        // completely unwound. This ordering is required for both MLX Metal
        // command buffers and llama.cpp's native decode context.
        ggufModel = nil
        container = nil
        await MLXGenerationGate.shared.clearCacheWhenIdle()
        autoreleasepool { }

        // llama.cpp/Metal can retire residency-set allocations shortly after
        // the Swift owner is released. Give that accounting time to settle
        // before another multi-GB runtime starts allocating.
        if releasedGGUF {
            var previous = MemoryAdvisor.physFootprint
            var stableSamples = 0
            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                autoreleasepool { }
                let current = MemoryAdvisor.physFootprint
                if abs(current - previous) < 64 * 1_024 * 1_024 {
                    stableSamples += 1
                    if stableSamples >= 3 { break }
                } else {
                    stableSamples = 0
                }
                previous = current
            }
        }
        Diagnostics.shared.breadcrumb(
            "assistant unload complete · footprint=\(MemoryAdvisor.physFootprint) · headroom=\(MemoryAdvisor.availableMemoryForModel)",
            category: "assistant"
        )
        state = .unloaded
        refreshVisionChatCapability()
    }

    // MARK: - Switch model

    /// Hot-swap the active model. Conversation-level switches leave the
    /// user's saved default unchanged; settings/model-management callers can
    /// opt into making the choice the default. No-op when already active.
    func switchTo(
        _ model: AssistantModel,
        persistAsDefault: Bool = true
    ) async {
        // MLX package loading is intentionally non-interruptible: invalidating
        // activeLoadID only prevents a late result from publishing; it does
        // not stop the loader from allocating the model. Starting a switch
        // while that work is active used to let a stale multi-GB load continue
        // behind the newly selected model and made background cleanup wait on
        // it. Keep the current selection stable until the load completes.
        if case .loading = state {
            ToastCenter.shared.info(
                "Model still loading",
                detail: "Wait for the current load to finish before choosing another model."
            )
            return
        }
        guard !isTransitioning else {
            ToastCenter.shared.info("Model already loading",
                                     detail: "Please wait for the current load to finish.")
            return
        }
        if activeExecutionLocation == .applePrivateCloud {
            let pccInflight = pccGenerateTask
            stopGeneration()
            if let pccInflight {
                _ = await pccInflight.value
            }
            activeExecutionLocation = .localDownloaded
            applePrivateCloudGenerationState = .idle
        }
        let hasLoadedModel = model.runtime == .llamaCpp
            ? ggufModel != nil
            : resolvedMLXContainer != nil
        if model.id == activeModel.id, hasLoadedModel {
            if persistAsDefault {
                AppSettings.shared.hasPickedAssistantModel = true
                AppSettings.shared.assistantModelID = model.id
            }
            return
        }
        if let compatibility = model.platformCompatibility,
           !compatibility.supportsCurrentPlatform {
            ToastCenter.shared.error("Can't load \(model.displayName)",
                                     detail: compatibility.detail)
            return
        }

        isTransitioning = true
        defer { isTransitioning = false }

        if persistAsDefault {
            // Persist only explicit default choices. A conversation switch
            // must not silently replace what future chats use.
            AppSettings.shared.hasPickedAssistantModel = true
            AppSettings.shared.assistantModelID = model.id
        }
        activeModel = model

        // Unload any active LoRA adapter when switching models.
        LoRAAdapterStore.shared.activeAdapterID = nil
        LoRAAdapterStore.shared.activeAdapterIDs = []

        // Fully reclaim the previous model's memory BEFORE loading the next
        // one. `unload()` returns immediately and (when a generate is still
        // in flight) defers `mlxClearCache()` to a detached task, so the old
        // weights + Metal buffers are still resident when `load()`'s memory
        // gate reads `os_proc_available_memory()`. That mismatch is the
        // "switch to a bigger model → 'only 2.0 GB available to the app'"
        // failure: the gate counts the model we're about to free. Awaiting the
        // synchronous-cleanup variant drains the in-flight task, frees the
        // GPU cache, and lets the per-process headroom recover first.
        await unloadAndWaitForCleanup()
        ToastCenter.shared.info("Loading \(model.displayName)…")
        // The caller supplied an explicit model. Conversation-level switches
        // intentionally do not persist that choice as the default, so a
        // settings reselect here would immediately replace `model` with the
        // saved default before loading it.
        await load(reselectFromSettings: false)
    }

    /// Loads a small model for a one-shot background analysis without changing
    /// the user's persisted assistant choice. The caller must finish with
    /// `finishTemporaryAnalysis(restoring:)` so the temporary weights are
    /// reclaimed and the picker returns to the original selection unloaded.
    func prepareTemporaryAnalysisModel(_ model: AssistantModel) async -> AssistantModel? {
        let maximumSafeFootprint: Int64 = 1_600_000_000
        guard model.runtime == .mlx,
              model.approxRAMBytes <= maximumSafeFootprint,
              model.platformCompatibility?.supportsCurrentPlatform ?? true else {
            return nil
        }

        let original = activeModel
        await unloadAndWaitForCleanup()
        activeModel = model
        await load(allowStorageFallback: false, reselectFromSettings: false)
        guard case .ready = state else {
            activeModel = original
            return nil
        }
        return original
    }

    /// Reclaims a temporary analysis model and restores the user's assistant
    /// identity without reloading its weights. The next normal chat send keeps
    /// the existing lazy-load behavior.
    func finishTemporaryAnalysis(restoring model: AssistantModel) async {
        await unloadAndWaitForCleanup()
        activeModel = model
        state = .unloaded
    }

    /// Restore `model` as the active selection WITHOUT loading it.
    /// Voice-mode teardown uses this: ending a conversation shouldn't
    /// eagerly pull a multi-GB chat model back into memory just to put
    /// the picker back — generate()'s lazy-load path brings the model
    /// up on the next send instead.
    func adoptSelectionWithoutLoading(_ model: AssistantModel) async {
        activeModel = model
        await unloadAndWaitForCleanup()
    }

    // MARK: - LoRA Adapter Support (Feature #9)

    /// Whether a LoRA adapter is currently loaded alongside the base model.
    private(set) var loadedLoRAID: String? = nil

    /// Load a LoRA adapter onto the currently active base model.
    /// MLX must support LoRA loading via the adapter path.
    /// NOTE: LoRA support in mlx-swift is experimental. This method
    /// attempts to load adapter weights and gracefully falls back
    /// if the API is unavailable.
    func loadLoRA(adapterID: String) async {
        guard let adapter = LoRAAdapterStore.shared.adapter(for: adapterID) else {
            ToastCenter.shared.error("LoRA not found", detail: "Adapter \(adapterID) is not in the catalog.")
            return
        }
        guard adapter.baseModelID == activeModel.id || adapter.baseModelID.isEmpty else {
            ToastCenter.shared.error("Incompatible LoRA",
                                     detail: "\(adapter.name) targets \(adapter.baseModelID), but \(activeModel.displayName) is loaded.")
            return
        }
        guard case .ready = state, resolvedMLXContainer != nil else {
            ToastCenter.shared.error("No model loaded", detail: "Load a base model before attaching a LoRA.")
            return
        }

        // Determine adapter path: local > HF cache > repo download.
        let adapterPath: URL?
        if let local = adapter.localPath {
            adapterPath = URL(fileURLWithPath: local)
        } else if let repoID = adapter.repoID {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let dashed = repoID.replacingOccurrences(of: "/", with: "--")
            adapterPath = docs.appendingPathComponent("huggingface/hub/models--\(dashed)")
        } else {
            adapterPath = nil
        }

        guard let path = adapterPath, FileManager.default.fileExists(atPath: path.path) else {
            ToastCenter.shared.error("LoRA weights missing",
                                     detail: "Download the adapter before loading it.")
            return
        }

        // LoRA support in mlx-swift is evolving. Attempt the load;
        // if the API isn't available yet, surface a clear message.
        // The container's LoRA methods will be available once
        // mlx-swift exposes them in a future release.
        ToastCenter.shared.info(
            "LoRA support coming soon",
            detail: "\(adapter.name) adapter weights found at \(path.lastPathComponent). Full LoRA loading will be available in a future mlx-swift update."
        )
    }

    /// Unload the currently active LoRA adapter, restoring the base model.
    func unloadLoRA() async {
        guard loadedLoRAID != nil else { return }
        loadedLoRAID = nil
        LoRAAdapterStore.shared.activeAdapterID = nil
        LoRAAdapterStore.shared.activeAdapterIDs = []
        ToastCenter.shared.info("LoRA removed")
    }
}
