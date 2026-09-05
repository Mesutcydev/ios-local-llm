import Foundation
import CoreImage
import UIKit
import Combine
import MLX
import MLXVLM
import MLXLMCommon
import MLXLMTransformers  // default TransformersLoader for loadContainer(from:configuration:)
import MLXRandom
import os

// MARK: - Per-family MLX execution policy

/// A catalog model is a support contract, so memory-sensitive families get an
/// explicit runtime profile instead of a one-size-fits-all allocator setting.
/// Repo ID is available before load; resolved architecture is supplied after
/// load for imported/custom models whose names do not identify the family.
struct MLXVLMExecutionProfile: Equatable, Sendable {
    let cacheLimitBytes: Int
    let maxOutputTokens: Int
    let maxKVSize: Int?
    let kvBits: Int?
    let prefillStepSize: Int
    let requiresSingleResidency: Bool

    static func resolve(repoID: String, architecture: String? = nil) -> Self {
        let identity = "\(repoID) \(architecture ?? "")".lowercased()
        if identity.contains("bonsai-27b") || identity.contains("qwen3_5") {
            // Qwen 3.5/Bonsai 27B is a large unified text+vision backbone.
            // Bound Lens activations/KV aggressively; Assistant and Lens may
            // share its one container, but no second model should coexist.
            return .init(
                cacheLimitBytes: 0,
                maxOutputTokens: 128,
                maxKVSize: 512,
                kvBits: 4,
                prefillStepSize: 128,
                requiresSingleResidency: true
            )
        }
        if identity.contains("gemma-3") || identity.contains("gemma3")
            || identity.contains("gemma-4") || identity.contains("gemma4") {
            return .init(
                cacheLimitBytes: 0,
                maxOutputTokens: 192,
                maxKVSize: 512,
                kvBits: 4,
                prefillStepSize: 128,
                requiresSingleResidency: true
            )
        }
        return .init(
            cacheLimitBytes: 64 * 1_024 * 1_024,
            maxOutputTokens: 256,
            maxKVSize: nil,
            kvBits: nil,
            prefillStepSize: 512,
            requiresSingleResidency: false
        )
    }
}

// MARK: - LensInferenceLoop
//
// Sole owner of the Lens tab's vision-language model. Replaces the
// streaming inference path that used to live in MLXVisionService;
// that class survives as a backward-compat shim for the 14 UI bindings
// it still has, but the container, capabilities, streaming hook, and
// one-shot describe all live here now. See
// See LENS_PIPELINE.md for the planned
// retirement of the shim.
//
// Two responsibilities, in order of importance:
//
//   1. **Container ownership.** A single `ModelContainer` resides
//      here while the Lens tab is active. Loaded via switchTo(),
//      torn down via unload(). Concurrent loads are guarded by the
//      same `loadingRepoID` latch the old service used — that
//      pattern is what prevents two simultaneous loadContainer()
//      calls from corrupting the MLX GPU scheduler.
//
//   2. **One-shot describe.** AnalysisService and the imported-image
//      pipeline ask "describe this image" through describe(image:…),
//      driven by the Lens tap-to-capture / interval loop in
//      CameraRootView. (A continuous per-frame streaming pipeline
//      used to live here too, fed by the camera's
//      `streamingFrameHandler`; it was never wired up — the Lens has
//      always been tap-to-capture — and was a crash-sensitive Metal
//      path, so it was removed. The voice narrator now reads the
//      one-shot describe results via AnalysisService.activeResult.)
//
// Threading: @MainActor like the class it replaces. describe() runs
// its image prep on the main actor (the CIImage graph is lazy) and
// dispatches the actual GPU pass through MLXGenerationGate.

@MainActor
final class LensInferenceLoop: ObservableObject {

    static let shared = LensInferenceLoop()

    // MARK: - State

    enum State: Equatable {
        case unloaded
        case loading(String)         // progress message
        case ready
        case generating
        case failed(String)
    }

    @Published private(set) var state: State = .unloaded

    /// Repo id of the currently-loaded model, nil when nothing is
    /// loaded. Mirrors the old MLXVisionService field for shim
    /// compatibility.
    @Published private(set) var activeRepoID: String?

    /// Resolved capabilities for the active model. Built immediately
    /// after switchTo() succeeds; consumed by LensFramePreparer and
    /// the debug overlay. nil when no model is loaded.
    @Published private(set) var capabilities: VLMCapabilities?

    /// Last preprocessed input the model saw — a debug-only
    /// thumbnail captured immediately before dispatch. Lens debug
    /// overlay reads this.
    @Published private(set) var lastModelInput: UIImage?

    /// Metadata about the last input (dimensions, timestamp,
    /// request UUID). Surfaced in the debug overlay.
    @Published private(set) var lastModelInputInfo: ModelInputInfo?

    /// Whether to keep the model loaded when the Lens tab
    /// deactivates. Default false: a multi-GB container resident
    /// while the user is on a different tab is exactly the kind
    /// of thing that gets the app killed by Jetsam during a
    /// background memory event. Power users can flip this if they
    /// want faster tab re-entry at the cost of memory pressure.
    var keepLoadedOnDeactivate: Bool = false


    /// End-to-end wall-clock latency of the last streaming
    /// inference, in milliseconds. Updated when each generation
    /// completes. Surfaced for the debug overlay; zero before any
    /// inference has run.
    @Published private(set) var lastInferenceMillis: Double = 0

    /// Tokens-per-second reported by the MLX generator on the last
    /// streaming inference. Zero before any inference has run.
    @Published private(set) var lastTokensPerSecond: Double = 0

    /// True while the lens debug overlay is on screen (set by
    /// LensDebugOverlay onAppear/onDisappear). The `lastModelInput` /
    /// `lastModelInputInfo` snapshots exist only for that overlay —
    /// building a UIImage per streaming inference when nothing reads
    /// it was pure waste, so the streaming path only populates them
    /// while this is true.
    var debugOverlayVisible: Bool = false

    /// Gate set to true during `.inactive`/`.background` lifecycle
    /// transitions. When true, `describe()` and `switchTo()` refuse
    /// new work so no Metal submissions start while the GPU is
    /// unavailable. Cleared on `.active`.
    private var newRequestsSuspended = false

    /// Block new Lens requests during lifecycle transitions.
    func suspendNewRequests() {
        newRequestsSuspended = true
        Diagnostics.shared.breadcrumb("Lens requests suspended", category: "lens")
    }

    /// Re-enable Lens requests after returning to foreground.
    func resumeNewRequests() {
        newRequestsSuspended = false
        Diagnostics.shared.breadcrumb("Lens requests resumed", category: "lens")
    }

    #if DEBUG
    /// Diagnostic toggle (DEBUG only). When `true`, the streaming
    /// loop bypasses LensFramePreparer and feeds the model a raw
    /// `CIImage(cvPixelBuffer:)` with no orientation, sRGB, or
    /// resize correction. Used by the lens debug overlay to
    /// isolate "prep bugs" from "model bugs" — if the model
    /// produces sensible captions when this is on, the bug is in
    /// prep; if it still hallucinates, the bug is in the model.
    /// Default off — accidentally enabling it on a release build
    /// would silently degrade every caption, so the flag is also
    /// compiled out of release entirely.
    var debugSendRaw: Bool = false
    #endif

    // MARK: - Stored state

    /// Wraps the captured-input debug data so the shim can re-export
    /// the same shape. Field-for-field identical to the old
    /// MLXVisionService.ModelInputInfo.
    struct ModelInputInfo: Equatable {
        let requestID: UUID
        let inputWidth: Int
        let inputHeight: Int
        let orientationApplied: String
        let capturedAt: Date
        let dispatchedAt: Date
    }

    private var container: ModelContainer?
    private var inferenceTask: Task<Void, Never>?

    /// Latched while a switchTo() is in flight. Two concurrent
    /// switchTo() calls without this guard race in loadContainer(),
    /// which corrupts the MLX GPU scheduler. Identical pattern to
    /// the old MLXVisionService's `loadingRepoID`.
    private var loadingRepoID: String?


    /// Observer for the memory-pressure cache-drop broadcast. Held for
    /// the singleton's (process-long) lifetime, never removed.
    private var dropCachesObserver: NSObjectProtocol?

    private init() {
        // Drop discardable debug state on memory pressure. The last-input
        // thumbnail + metadata exist only for the lens debug overlay — the
        // cheapest possible reclaim when MemoryPressureCoordinator posts
        // .iosLocalLLMDropDiscardableCaches.
        dropCachesObserver = NotificationCenter.default.addObserver(
            forName: .iosLocalLLMDropDiscardableCaches,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lastModelInput = nil
                self?.lastModelInputInfo = nil
            }
        }
    }


    // MARK: - Load lifecycle

    /// Switch (or initial-load) the active VLM to `repoID`. Same
    /// fallback-list walk as the old MLXVisionService.switchTo —
    /// preserves the "primary failed, trying SmolVLM2" UX so a
    /// 404 on the user's primary doesn't dead-end the camera tab.
    /// Returns the unified VLM container only for a declared dual-role model.
    /// Assistant uses this accessor instead of loading a second LLM copy.
    func sharedContainer(for repoID: String) -> ModelContainer? {
        guard DualRoleModelPolicy.isTextAndVision(repoID: repoID),
              activeRepoID?.caseInsensitiveCompare(repoID) == .orderedSame else {
            return nil
        }
        return container
    }

    func switchTo(repoID: String, preserveMatchingAssistant: Bool = false) async {
        // Lifecycle guard: refuse loads during .inactive/.background transitions.
        guard !newRequestsSuspended else {
            Diagnostics.shared.breadcrumb(
                "Lens switchTo blocked · requests suspended · \(repoID)",
                category: "lens"
            )
            return
        }
        // Only the Assistant-owned call path may suppress Assistant teardown.
        // Merely selecting the same repository in both pickers does not mean
        // the two tabs currently share one container: Assistant may own a
        // smaller text-only runtime. Treating matching selections as shared
        // caused Lens and Assistant to load on top of each other.
        let preserveAssistant = preserveMatchingAssistant
        // Same model already loaded — noop, but recover a stuck `.failed`
        // left behind by a prior describe() error so the next Ask tap
        // doesn't keep returning "could not process this frame".
        if let active = activeRepoID, active == repoID, container != nil {
            await drainCompetingRuntimes(preservingAssistant: preserveAssistant)
            if case .failed = state {
                Diagnostics.shared.notice(
                    "VLM recovered from prior failure · \(repoID.components(separatedBy: "/").last ?? repoID)",
                    category: "lens"
                )
                state = .ready
            }
            // Do not turn `.generating` into `.ready`. AnalysisService can
            // re-enter switchTo when a second Ask arrives; lying about state
            // allowed another describe to cancel/replace live Metal work.
            return
        }

        // Cross-repository transition guard. The latch must be claimed BEFORE
        // the first await (assistant teardown / inference drain). Build 15 set
        // it after memory preflight, leaving a multi-second window where Gemma
        // and Qwen switches both entered and loaded two containers in series,
        // with the first still resident during the second load.
        if let loadingRepoID {
            Diagnostics.shared.breadcrumb(
                "VLM switch ignored · requested=\(repoID) · already loading=\(loadingRepoID)",
                category: "lens"
            )
            return
        }
        loadingRepoID = repoID
        defer { if loadingRepoID == repoID { loadingRepoID = nil } }

        // Cancel the old inference, wait for the app-wide MLX gate to drain,
        // and only then clear buffers. Swift Task.cancel() is cooperative and
        // does not interrupt an already-submitted Metal command buffer.
        await unloadForModelSwitch()
        await drainCompetingRuntimes(preservingAssistant: preserveAssistant)

        // Memory gate. Refuse a load if we don't have ~1.6× the
        // estimated weight size available in process.
        //
        // The 1.6× multiplier (previously 1.4×) covers the TRANSIENT
        // LOAD PEAK — during the `pread` phase MLX is reading from
        // disk + unpacking 4-bit weights + uploading to Metal in
        // parallel, and the working set briefly exceeds the
        // steady-state weights size. A user-reported EXC_RESOURCE
        // crash at exactly that phase (line 359 of mlx-swift's
        // ParallelFileReader::read) is what motivated the bump:
        // the 1.4× gate let a 5.4 GB Qwen3-VL-8B start loading on
        // a 17 Pro Max with a 6 GB process cap, peak load crossed
        // the watermark, process was killed.
        //
        // 1.6× is conservative enough to refuse loads that would
        // crash, while still allowing all the Qwen3-VL variants
        // currently in the catalog to load on their target tiers.
        //
        // Smart-recovery path: if the gate would refuse, FIRST try
        // unloading the LLM (the cross-tab model). On iPhones the
        // per-process memory limit caps below the device's total
        // RAM — even with the increased-memory-limit entitlement, a
        // 12 GB device gives ~5–7 GB per process. If the assistant
        // LLM is resident, available memory after subtracting it can
        // be tight. Unloading the LLM is the natural way to free
        // memory before the VLM load; only after that, if we STILL
        // don't have enough, do we surface the error. This makes the
        // dual-residence policy (ModelResidency.canResideTogether)
        // "soft" — the static tier budget is the upper bound; runtime
        // memory pressure can force single-residence even when both
        // would notionally fit.
        let estimated = Self.estimatedWeightBytes(repoID: repoID)
        let executionProfile = MLXVLMExecutionProfile.resolve(repoID: repoID)
        // Gemma's SigLIP tower always runs at 896² (~4096 patches). Load
        // transients and vision activations happen in different phases, so
        // adding both peaks rejects models whose phases fit independently.
        // Admit against the larger phase and let MLX's total-allocation cap
        // serialize buffers within that envelope.
        let activationReserve = Self.visionActivationReserveBytes(repoID: repoID)
        let measuredPeak = Self.phaseAwarePeakBytes(
            weightBytes: estimated,
            activationReserveBytes: activationReserve
        )
        // Curated VLMs carry an end-to-end working-set estimate. Imported
        // models have no declaration, so their measured file sizes drive the
        // same phase-aware calculation above.
        let declaredPeak = UInt64(max(0, ModelDownloadCenter.shared.models
            .first(where: {
                $0.id.caseInsensitiveCompare(repoID) == .orderedSame
                    || $0.sourceRepoID.caseInsensitiveCompare(repoID) == .orderedSame
            })?.approxRAMBytes ?? 0))
        let peakNeeded = max(measuredPeak, declaredPeak)
        // A peak that merely equals live process headroom is not safe: the
        // camera, SwiftUI, Core Image and allocator bookkeeping still need room.
        // The missing fixed reserve was the Gemma-on-iPhone18,2 jetsam hole.
        let required = Self.requiredLoadBytes(peakBytes: peakNeeded)

        // Always drop the chat LLM before a single-resident VLM — dual
        // residence cannot fit under the process ceiling even when the weight
        // gate alone looks green.
        if executionProfile.requiresSingleResidency && !preserveAssistant {
            Diagnostics.shared.breadcrumb("heavy vision model — unloading LLM before load", category: "lens")
            await CodingAssistantService.shared.unloadAndWaitForCleanup()
            await MLXGenerationGate.shared.clearCacheWhenIdle()
        }

        // Post-critical-pressure cooldown — same window safetyBlocker
        // enforces (via MemoryAdvisor.pressureCooldownRemaining), so a heavy
        // VLM reload can't race iOS while it's still reclaiming after an
        // emergency dump. Recovery is allowed when the VLM COMFORTABLY fits the
        // live headroom (full reserve kept) — mirrors MemoryAdvisor.safetyBlocker.
        // The previous `needed <= smallRecoveryModelCeiling` (1 GB) clause kept
        // the lens stuck for the whole window because every real VLM is larger.
        if let remaining = MemoryAdvisor.pressureCooldownRemaining {
            let fitsAsRecovery = Int64(required) <= MemoryAdvisor.availableMemoryForModel
            if !fitsAsRecovery {
                let secs = max(1, Int(remaining.rounded(.up)))
                state = .failed("iOS just reported a memory-pressure spike. Wait ~\(secs)s for it to recover memory, then retry.")
                return
            }
        }

        // Entitlement-aware live headroom, NOT raw os_proc_available_memory()
        // — the latter under-reports on entitled devices and refused VLMs
        // that comfortably fit (see MemoryAdvisor.availableMemoryForModel).
        var available = UInt64(max(0, MemoryAdvisor.availableMemoryForModel))
        Diagnostics.shared.breadcrumb(
            "VLM preflight · \(repoID) · peak=\(Int64(peakNeeded).formattedBytes) · required=\(Int64(required).formattedBytes) · available=\(Int64(available).formattedBytes) · ceiling=\(MemoryAdvisor.processMemoryCeiling.formattedBytes) · footprint=\(MemoryAdvisor.physFootprint.formattedBytes) · kernel=\(MemoryAdvisor.processAvailableMemory.formattedBytes)",
            category: "lens"
        )
        if available < required && !preserveAssistant {
            Diagnostics.shared.breadcrumb(
                "memory tight (need \(required/1_048_576) MB including reserve, have \(available/1_048_576) MB) — unloading LLM to free RAM",
                category: "lens"
            )
            await CodingAssistantService.shared.unloadAndWaitForCleanup()
            // Flush the reclaimable MLX/Metal buffer pool now that the LLM
            // teardown has been awaited (Metal is idle — safe to clear). This
            // releases the PREVIOUS VLM's pooled buffers too: it was unloaded
            // above with `clearGPUCache: false`, so without this flush its
            // (fully reclaimable) memory is still counted against the new
            // model and a VLM that fits gets refused.
            await MLXGenerationGate.shared.clearCacheWhenIdle()
            // The kernel's accounting can lag slightly behind the
            // teardown, so poll briefly instead of relying on one
            // fixed sleep. This avoids a false second miss when the
            // LLM just finished releasing its Metal buffers.
            for _ in 0..<10 {
                available = UInt64(max(0, MemoryAdvisor.availableMemoryForModel))
                if available >= required { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if available < required {
            let needMB = Double(required) / 1_048_576
            let haveMB = Double(available) / 1_048_576
            let message = String(format:
                "This vision model cannot load safely here. It needs ~%.0f MB including app headroom, but only %.0f MB is available. Pick Qwen3-VL 4B/2B or SmolVLM2 instead.",
                needMB, haveMB)
            Diagnostics.shared.warning(message, category: "lens")
            state = .failed(message)
            return
        }

        // Pre-flight thermal gate. Only refuse on .critical; .serious
        // we still allow because inference is throttled separately
        // by DeviceSafetyMonitor.recommendedMaxTokens.
        let safety = DeviceSafetyMonitor.shared
        if safety.effectiveThermalState == .critical {
            state = .failed("Device is critically hot — let it cool before loading.")
            return
        }

        // Build the candidate list: primary first, then any
        // MLX fallback repos that aren't the primary. A GGUF fallback must
        // route through LlamaCppVLMService; handing its directory to
        // VLMModelFactory only creates a guaranteed failed load and extra
        // allocator churn.
        var candidates: [String] = [repoID]
        for fallback in DeviceTierAdvisor.visualModelFallbackRepoIDs
        where fallback != repoID
            && LocalModelRegistry.visionRuntime(
                forStoredSelectionID: fallback,
                catalog: ModelDownloadCenter.shared.models
            ) == .mlx {
            candidates.append(fallback)
        }

        var lastError: String?
        for (index, candidate) in candidates.enumerated() {
            guard loadingRepoID == repoID else {
                state = .unloaded
                return
            }
            // Open with "Preparing" by default and only switch to
            // "Downloading" once we've seen genuine network-slow
            // progress (≥3 s elapsed AND <20% complete). Same
            // policy as CodingAssistantService.load — a cached VLM
            // should never flash "Downloading" while it's actually
            // mmap-paging from disk.
            let probedWarm = Self.isRepoCachedLocally(candidate)
            let shortName = candidate.split(separator: "/").last.map(String.init) ?? candidate

            if index > 0 {
                state = .loading("Primary failed — trying \(shortName)…")
                ToastCenter.shared.info("Switching VLM", detail: "Falling back to \(shortName)")
            } else {
                state = .loading("Preparing \(shortName)…")
            }
            let loadStart = Date()

            // Latch flips from "Preparing" → "Downloading" once a
            // load looks like a real network transfer. Class so the
            // @Sendable progress closure can mutate without
            // capturing self.
            final class VerbLatch: @unchecked Sendable {
                private let lock = NSLock()
                private var _isNetwork: Bool
                init(_ v: Bool) { _isNetwork = v }
                var isNetwork: Bool { lock.withLock { _isNetwork } }
                func markNetwork() { lock.withLock { _isNetwork = true } }
            }
            let latch = VerbLatch(false)

            // Prefer a directory-based config when weights are
            // pre-staged — avoids MLX re-fetching from HuggingFace
            // for "local/..." repoIDs and double-disk-use for real
            // ones.
            let stagedURL = Self.stagedDirectory(for: candidate)
            let config: ModelConfiguration
            if let staged = stagedURL {
                config = ModelConfiguration(directory: staged, defaultPrompt: "Describe the image.")
            } else {
                config = ModelConfiguration(id: candidate, defaultPrompt: "Describe the image.")
            }

            do {
                let candidateProfile = MLXVLMExecutionProfile.resolve(repoID: candidate)
                let loaded = try await MLXGenerationGate.shared.run {
                    try await Self.withMLXMemoryCap(
                        cacheLimitBytes: candidateProfile.cacheLimitBytes
                    ) {
                        let c = try await VLMModelFactory.shared.loadContainer(from: HubApiDownloader(), configuration: config) { progress in
                            let pct = Int(progress.fractionCompleted * 100)
                            let elapsed = Date().timeIntervalSince(loadStart)
                            if !latch.isNetwork,
                               !probedWarm,
                               elapsed > 3.0,
                               progress.fractionCompleted < 0.20 {
                                latch.markNetwork()
                            }
                            Task { @MainActor [weak self, latch] in
                                let verb = latch.isNetwork ? "Downloading" : "Preparing"
                                self?.state = .loading("\(verb) \(pct)%")
                            }
                        }
                        mlxClearCache()
                        return c
                    }
                }
                guard loadingRepoID == repoID,
                      UIApplication.shared.applicationState == .active else {
                    // An explicit unload/tab switch or background transition
                    // superseded this load while native code was finishing.
                    // Drop the result instead of resurrecting a resident model.
                    state = .unloaded
                    await MLXGenerationGate.shared.clearCacheWhenIdle()
                    return
                }
                container = loaded
                activeRepoID = candidate
                let memoryAfterLoad = MLX.Memory.snapshot()

                // Build capabilities from the staged directory's
                // JSON. If staging failed for this candidate (it
                // was lazy-fetched via HubApi), the directory is
                // typically `Documents/huggingface/models/<repoID>/`
                // — resolve it now via stagedDirectory(), which
                // re-runs the same probe MLX did internally.
                let dir = stagedURL ?? Self.stagedDirectory(for: candidate)
                if let dir {
                    capabilities = VLMCapabilities.load(modelDirectory: dir, repoID: candidate)
                } else {
                    // Last-resort fallback: assume the unknown
                    // architecture. The debug overlay's description
                    // will say "unknown · fixed(384×384) · …" which
                    // is the signal to add a NormalizedArchitecture
                    // entry for this model.
                    capabilities = VLMCapabilities.load(modelDirectory: URL(fileURLWithPath: "/"), repoID: candidate)
                }

                state = .ready
                Diagnostics.shared.notice(
                    "MLX VLM ready · \(shortName) · active=\(Int64(memoryAfterLoad.activeMemory).formattedBytes) · cache=\(Int64(memoryAfterLoad.cacheMemory).formattedBytes) · footprint=\(MemoryAdvisor.physFootprint.formattedBytes)",
                    category: "lens"
                )
                LocalModelRegistry.setVisionSelection(candidate)
                ToastCenter.shared.success("Vision model ready", detail: candidate)
                // VLM is loaded and idle. Schedule a background
                // prefetch of the LLM's weight files into the OS
                // page cache. See ModelResidency for the rationale.
                ModelResidency.shared.schedulePrefetch(currentTab: .lens)
                return
            } catch is MLXGenerationGate.Cancelled {
                // Backgrounded or cancelAll() fired mid-load — clean
                // cancel, don't walk the fallback list.
                container = nil
                activeRepoID = nil
                capabilities = nil
                state = .unloaded
                return
            } catch {
                lastError = error.localizedDescription
                Diagnostics.shared.warning(
                    "VLM candidate failed · \(candidate) · \(error.localizedDescription)",
                    category: "lens"
                )
                container = nil
                activeRepoID = nil
                capabilities = nil
                // Return partial load buffers before trying a fallback. Put
                // reclamation on the gate too: another app subsystem may have
                // enqueued MLX work immediately after this load body exited.
                // A direct clear here could race that newly-admitted command.
                await MLXGenerationGate.shared.clearCacheWhenIdle()
            }
        }

        state = .failed(lastError ?? "Unknown error")
        ToastCenter.shared.error("VLM failed to load",
                                  detail: lastError ?? "All known VLM mirrors are unreachable.")
    }

    /// Cancel any in-flight inference without unloading the model.
    /// Called when the app goes inactive so iOS doesn't kill in-
    /// flight Metal command buffers.
    func cancelCurrentInference() {
        inferenceTask?.cancel()
        inferenceTask = nil
        if case .generating = state { state = .ready }
    }

    /// Tear down the container and enqueue GPU-buffer reclamation after all
    /// admitted MLX work. Cancellation alone cannot stop a Metal command that
    /// has already been submitted, so cache clearing must share the gate.
    func unload(clearGPUCache: Bool = true) {
        let inflight = inferenceTask
        inferenceTask = nil
        inflight?.cancel()
        // Supersede an in-progress switchTo so its eventual load result is
        // discarded by the guard immediately after MLXGenerationGate.run.
        loadingRepoID = nil
        container = nil
        activeRepoID = nil
        capabilities = nil
        state = .unloaded
        guard clearGPUCache else { return }
        // Queue reclamation behind every admitted MLX operation, including a
        // model load (which is not stored in `inferenceTask`). This is safe for
        // tab switches, backgrounding, and memory-pressure unloads.
        Task { @MainActor in
            await MLXGenerationGate.shared.clearCacheWhenIdle()
            _ = await inflight?.value
            autoreleasepool { }
        }
    }

    /// Synchronous-from-the-caller teardown used only by switchTo. Unlike the
    /// public fire-and-forget unload, this does not return until native MLX work
    /// has drained and the allocator cache has been reclaimed, guaranteeing the
    /// next model cannot overlap the previous inference's Metal buffers.
    private func unloadForModelSwitch() async {
        let inflight = inferenceTask
        let previousRepo = activeRepoID
        let footprintBefore = MemoryAdvisor.physFootprint
        inferenceTask = nil
        inflight?.cancel()
        container = nil
        activeRepoID = nil
        capabilities = nil
        state = .unloaded

        await MLXGenerationGate.shared.clearCacheWhenIdle()
        _ = await inflight?.value
        // The cancelled task's completion handler may have restored `.ready`;
        // reassert the actual empty residency after it has fully exited.
        state = .unloaded
        autoreleasepool { }

        if previousRepo != nil || inflight != nil {
            Diagnostics.shared.breadcrumb(
                "VLM drained before switch · \(previousRepo ?? "none") · footprint \(footprintBefore.formattedBytes) → \(MemoryAdvisor.physFootprint.formattedBytes)",
                category: "lens"
            )
        }
    }

    /// The Lens is intentionally single-runtime. Static "both fit" estimates
    /// do not cover camera buffers, allocator peaks, or native work still
    /// finishing after cancellation. Drain every competing backend before an
    /// MLX VLM can remain active or begin loading.
    private func drainCompetingRuntimes(preservingAssistant: Bool = false) async {
        if !preservingAssistant {
            await CodingAssistantService.shared.unloadAndWaitForCleanup()
        }
        await LlamaCppVLMService.shared.unloadAndWaitForCleanup()
        FastVLMService.shared.unload()
        await MLXGenerationGate.shared.clearCacheWhenIdle()
    }


    // MARK: - One-shot describe
    //
    // Ported from MLXVisionService.describe(). Behavior is intended
    // to match the old path, with ONE deliberate drift:
    //
    //   The resize hint used to be hardcoded `448 × 448` regardless
    //   of which VLM was loaded. It now reads
    //   `Self.resizeHintSide(for: caps)`, which for SmolVLM2 returns
    //   384 (the model's actual tile size) instead of 448.
    //
    // For most outputs this should be neutral-to-better — the model
    // sees a hint that matches its declared expectations. But it's
    // the single most likely source of token-level drift in the
    // shim path, and the validation pass should explicitly compare
    // outputs against the pre-migration behavior on a known image
    // through `AnalysisService.tryMLXVisionPath`.
    //
    // If validation shows the drift is too large, the fix is to
    // ignore `caps` in this function and hardcode 448 — the
    // streaming path keeps the strategy-aware hint, the one-shot
    // path reverts to the old behavior. That isolates the change.
    //
    // The defensive `upscaleIfTiny` guard is preserved verbatim.
    // It's now belt-and-suspenders rather than the sole defense
    // — the `withError { error in ... }` wrap inside container.perform
    // (below) converts MLX C++ errors into Swift `MLXError.caught(...)`
    // throws via mlx-swift's task-local handler. So a broadcast-shapes
    // error on a tiny input is recoverable now; upscaleIfTiny still
    // produces a *useful* caption instead of a thrown error, which
    // is the better outcome when we can predict and prevent the
    // error. The wrap covers the cases we can't predict.

    func describe(
        image: UIImage,
        prompt: String = "Describe what's in this image. Be concise.",
        maxTokens: Int = 256,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping (Double) -> Void
    ) {
        guard case .ready = state, let container else {
            onComplete(0)
            return
        }
        // Thermal/memory safety gate — same as the streaming path. No
        // new GPU work while the device is critically hot or under
        // sustained memory pressure.
        if DeviceSafetyMonitor.shared.shouldStopHeavyWork {
            onComplete(0)
            return
        }
        // Background guard. iOS revokes GPU access for backgrounded apps;
        // a describe fired during the scene-transition window will hit
        // kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted
        // when the command buffer completion handler runs, and MLX rethrows
        // that as an uncatchable C++ std::runtime_error. The gate refuses
        // new submissions too, but bailing here saves the image-prep work
        // and avoids a no-op .generating → .ready state churn.
        if UIApplication.shared.applicationState != .active {
            onComplete(0)
            return
        }
        // Lifecycle controller guard: during .inactive/.background
        // transitions, refuse all new Lens work. The existing background
        // guard above catches the steady-state case; this covers the
        // transient window where the GPU is still accessible but the
        // pipeline is draining.
        if newRequestsSuspended {
            onComplete(0)
            return
        }
        guard let rawCG = image.cgImage else {
            onComplete(0)
            return
        }
        // Same broken-architecture guard as the streaming path. The
        // describe path goes through the same upstream
        // prepareInputsForMultimodal that crashes for Idefics3 /
        // SmolVLM / SmolVLM2 — block it here before we hand control
        // to mlx-swift-examples.
        if let caps = capabilities, !caps.isLensPipelineCompatible {
            if Self.recoverFromSmolVLMSelection(capabilities: caps) {
                onComplete(0)
                return
            }
            state = .failed(caps.incompatibilityReason)
            ToastCenter.shared.error("Model not compatible",
                                      detail: caps.incompatibilityReason)
            onComplete(0)
            return
        }
        // Strategy-aware sizing — this dispatches on the model's
        // input-sizing strategy (from capabilities) to pick the
        // right resize policy. Earlier versions used `fitToTileLong-
        // Edge` for ALL strategies, which is correct for fixed-tile
        // models (SmolVLM family) but throws away resolution for
        // dynamicPatchAligned models (Qwen-VL family): a 1920×1080
        // screen capture was being scaled to 512×288, ~7× resolution
        // loss, making screen text unreadable.
        //
        // The compatibility guard above already blocks SmolVLM /
        // Idefics3, so in practice the dispatcher only ever hits the
        // dynamicPatchAligned branch (Qwen-VL is the only currently-
        // recommended family). Other branches are retained for
        // correctness in case future models route through here.
        let cg = Self.sizedForStill(rawCG, capabilities: capabilities)
        let ciImage = CIImage(cgImage: cg)
        let executionProfile = MLXVLMExecutionProfile.resolve(
            repoID: activeRepoID ?? "",
            architecture: capabilities?.architecture
        )
        let cap = Swift.min(
            maxTokens,
            DeviceSafetyMonitor.shared.recommendedMaxTokens,
            executionProfile.maxOutputTokens
        )

        // A catalog estimate can be wrong even when load preflight succeeded.
        // Re-check the measured loaded footprint before image encoding, where
        // vision activations are allocated on top of the resident weights. In
        // build 45 Bonsai 27B loaded at ~5.3 GB, then its first Lens request
        // lifted the process past the iPhone Jetsam watermark. Refuse before
        // submitting Metal work when the measured footprint + family reserve
        // cannot fit beneath the platform ceiling.
        let footprintBefore = MemoryAdvisor.physFootprint
        let activationReserve = Int64(Self.visionActivationReserveBytes(
            repoID: activeRepoID ?? ""
        ))
        let inferenceNeeded = footprintBefore + activationReserve
            + MemoryAdvisor.loadHeadroomReserve
        let processCeiling = MemoryAdvisor.processMemoryCeiling
        if footprintBefore > 0, processCeiling > 0, inferenceNeeded > processCeiling {
            let message = String(
                format: "This model loaded, but image analysis would exceed this device's safe memory budget (~%.1f GB needed, ~%.1f GB budget). Pick Bonsai 8B, Qwen3-VL 4B/2B, or SmolVLM2 instead.",
                Double(inferenceNeeded) / 1_000_000_000,
                Double(processCeiling) / 1_000_000_000
            )
            Diagnostics.shared.warning(
                "VLM inference refused · \(activeRepoID ?? "unknown") · footprint=\(footprintBefore.formattedBytes) · activation=\(activationReserve.formattedBytes) · ceiling=\(processCeiling.formattedBytes)",
                category: "lens"
            )
            state = .failed(message)
            ToastCenter.shared.error("Model is too large for Lens", detail: message)
            onComplete(0)
            return
        }
        state = .generating
        // Cancel pending prefetch — same reasoning as the streaming path.
        ModelResidency.shared.cancelPrefetch()

        let requestID = UUID()
        let capturedAt = Date()
        let debugThumb = Self.thumbnail(from: cg, maxDim: 480)
        let info = ModelInputInfo(
            requestID: requestID,
            inputWidth: cg.width,
            inputHeight: cg.height,
            orientationApplied: "right (caller-applied)",
            capturedAt: capturedAt,
            dispatchedAt: Date()
        )
        self.lastModelInput = debugThumb
        self.lastModelInputInfo = info
            Diagnostics.shared.breadcrumb(
                "describe req=\(requestID) size=\(cg.width)×\(cg.height)",
                category: "lens"
            )

        let caps = capabilities
        inferenceTask?.cancel()
        inferenceTask = Task {
            do {
                MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))
                try await MLXGenerationGate.shared.run { [container, caps, executionProfile] in
                    try await Self.withMLXMemoryCap(
                        cacheLimitBytes: executionProfile.cacheLimitBytes
                    ) {
                        mlxClearCache()
                        defer { mlxClearCache() }
                        MLX.Memory.peakMemory = 0
                        try await container.perform { (context: ModelContext) -> Void in
                            // `withError` placement rationale: task-local
                            // handler installed inside container.perform
                            // (because the gate spawns
                            // an unstructured Task that wouldn't inherit
                            // a handler set outside), `error.check()` at
                            // the natural break points.
                            try await withError { error in
                                let images: [UserInput.Image] = [.ciImage(ciImage)]
                                let chat: [Chat.Message] = [
                                    .system("You are an image understanding model capable of describing the salient features of any image."),
                                    .user(prompt, images: images, videos: []),
                                ]
                                var userInput = UserInput(chat: chat)
                                // Resize hint: pull from capabilities when
                                // available so the hint matches the model's
                                // actual expectations. Falls back to 448 to
                                // preserve the old behavior when no caps
                                // were resolved.
                                let hintSide = caps.map(Self.resizeHintSide(for:)) ?? 448
                                userInput.processing.resize = .init(width: hintSide, height: hintSide)
                                let lmInput = try await context.processor.prepare(input: userInput)
                                try error.check()
                                let params = GenerateParameters(
                                    maxTokens: cap,
                                    maxKVSize: executionProfile.maxKVSize,
                                    kvBits: executionProfile.kvBits,
                                    quantizedKVStart: 0,
                                    temperature: 0.7,
                                    topP: 0.9,
                                    prefillStepSize: executionProfile.prefillStepSize
                                )
                                let stream = try MLXLMCommon.generate(
                                    input: lmInput, parameters: params, context: context
                                )
                                var lastRate: Double = 0
                                for await piece in stream {
                                    if Task.isCancelled { break }
                                    try error.check()
                                    if let chunk = piece.chunk, !chunk.isEmpty {
                                        onToken(chunk)
                                    }
                                    if let info = piece.info {
                                        lastRate = info.tokensPerSecond
                                    }
                                }
                                let finalRate = lastRate
                                onComplete(finalRate)
                                let memoryAfter = MLX.Memory.snapshot()
                                let footprintAfter = MemoryAdvisor.physFootprint
                                await MainActor.run {
                                    // Same persisted-usage hook as the streaming
                                    // auto-loop above, so one-shot describe()
                                    // runs also feed the picker's avg-tok/s pill.
                                    if let id = self.activeRepoID, finalRate > 0 {
                                        ModelUsageTracker.shared.recordGeneration(
                                            modelID: id, tokens: 0, tokensPerSecond: finalRate
                                        )
                                    }
                                    Diagnostics.shared.breadcrumb(
                                        "MLX VLM inference · \(caps?.architecture ?? "unknown") · tokens≤\(cap) · active=\(Int64(memoryAfter.activeMemory).formattedBytes) · cache=\(Int64(memoryAfter.cacheMemory).formattedBytes) · peak=\(Int64(memoryAfter.peakMemory).formattedBytes) · footprint \(footprintBefore.formattedBytes) → \(footprintAfter.formattedBytes)",
                                        category: "lens"
                                    )
                                }
                            }
                        }
                    }
                }
                await MainActor.run {
                    self.state = .ready
                    // Prefetch is intentionally not re-armed after inference.
                    // The optimization is load-triggered and charging-only;
                    // repeated idle disk reads made long sessions warmer.
                }
            } catch is CancellationError {
                await MainActor.run { self.state = .ready; onComplete(0) }
            } catch is MLXGenerationGate.Cancelled {
                await MainActor.run { self.state = .ready; onComplete(0) }
            } catch {
                await MainActor.run {
                    self.state = .failed(error.localizedDescription)
                    onComplete(0)
                }
            }
        }
    }

    // MARK: - Debug helpers

    /// Save the last preprocessed input as a PNG in Documents.
    /// Wired up by the Settings → INTERFACE → "save last model
    /// input" button so the user can pull the image off the device
    /// and feed it to another VLM for parity testing.
    @discardableResult
    func saveLastModelInputToDocuments() -> URL? {
        guard let img = lastModelInput, let png = img.pngData() else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = docs.appendingPathComponent("lens-model-input-\(stamp).png")
        do {
            try png.write(to: url)
            Diagnostics.shared.breadcrumb("saved model input", category: "lens")
            return url
        } catch {
            Diagnostics.shared.error(
                "save failed: \(error.localizedDescription)",
                category: "lens"
            )
            return nil
        }
    }

    // MARK: - Cache lookup
    //
    // Ported from MLXVisionService — same logic, same priority order.
    // Without this, every launch falls through to HubApi which silently
    // re-fetches weights that are already on disk.

    static nonisolated func stagedDirectory(for repoID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dirName = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let flattened = repoID.replacingOccurrences(of: "/", with: "_")
        let candidates: [URL] = [
            docs.appendingPathComponent("huggingface")
                .appendingPathComponent("models")
                .appendingPathComponent(repoID),
            docs.appendingPathComponent("HFModels").appendingPathComponent(repoID),
            docs.appendingPathComponent("HFModels").appendingPathComponent(flattened),
            docs.appendingPathComponent("HFModels").appendingPathComponent(dirName),
            // Assistant catalog downloads land here. Dual-role packages must
            // be consumed in place by Lens instead of downloaded again.
            docs.appendingPathComponent("LLMModels").appendingPathComponent(dirName),
            docs.appendingPathComponent("FastVLMModels").appendingPathComponent(dirName),
        ]
        return candidates.first(where: ModelCacheProbe.isUsableModelDirectory)
    }

    private static func isRepoCachedLocally(_ repoID: String) -> Bool {
        stagedDirectory(for: repoID) != nil
    }

    /// Recovery path for the broken-architecture guard. When the user
    /// has selected an MLX SmolVLM2 / SmolVLM / Idefics3 variant (all
    /// crash the prepareInputsForMultimodal call in mlx-swift-examples)
    /// AND the bundled SmolVLM2-500M GGUF is staged on disk, swap the
    /// camera-VLM selection to the GGUF so the next dispatch routes
    /// through LlamaCppVLMService instead. That path has its own
    /// message generator and doesn't share the bug.
    ///
    /// Returns true when a swap happened — the caller should then bail
    /// the current dispatch and let the system pick up the new ID.
    /// Returns false when no swap was made; the caller should fall back
    /// to the existing "show failure" behaviour.
    @MainActor
    private static func recoverFromSmolVLMSelection(capabilities: VLMCapabilities) -> Bool {
        guard capabilities.isSmolVLMFamily else { return false }
        let bundledID = BundledVLMInstaller.bundledRepoID
        guard LlamaCppVLMService.stagedDirectory(for: bundledID) != nil else {
            return false
        }
        let settings = AppSettings.shared
        let currentSelection = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        guard currentSelection != bundledID else { return false }
        LocalModelRegistry.setVisionSelection(bundledID, settings: settings)
        ToastCenter.shared.info(
            "Switched to SmolVLM2-500M (GGUF)",
            detail: "The MLX variant has a known upstream bug. Reloading with the bundled GGUF, which runs through llama.cpp."
        )
        return true
    }

    /// Sum weight-file sizes in `dir` for the memory-gate estimate.
    /// Returns 0 if the directory doesn't exist or contains no
    /// recognizable weight files — caller treats 0 as "unknown" and
    /// falls back to the conservative 3 GB default.
    private static nonisolated func cachedWeightBytes(_ dir: URL) -> UInt64 {
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

    /// Best-effort weight-size estimate for the memory gate. If
    /// weights are pre-staged, sum the actual files; otherwise
    /// fall back to a conservative default that covers the largest
    /// VLM in the catalog (~6 GB for Qwen3-VL-8B 4-bit; floor of 3 GB
    /// for older defaults).
    ///
    /// `static` and `nonisolated` so ModelResidency can call it from
    /// any actor context — it's pure file-IO + arithmetic.
    static nonisolated func estimatedWeightBytes(repoID: String) -> UInt64 {
        if let dir = stagedDirectory(for: repoID) {
            let measured = cachedWeightBytes(dir)
            if measured > 0 { return measured }
        }
        return UInt64(3 * 1_073_741_824)   // 3 GB
    }

    /// Complete Lens load budget for a repository. Unlike Assistant's text
    /// footprint, this includes the model family's vision activation envelope
    /// and the fixed app/camera reserve. The catalog lookup accepts either an
    /// app preset slug or its canonical repository ID.
    @MainActor
    static func requiredVisionLoadBytes(repoID: String) -> UInt64 {
        let estimated = estimatedWeightBytes(repoID: repoID)
        let activationReserve = visionActivationReserveBytes(repoID: repoID)
        let measuredPeak = phaseAwarePeakBytes(
            weightBytes: estimated,
            activationReserveBytes: activationReserve
        )
        let declaredPeak = UInt64(max(0, ModelDownloadCenter.shared.models
            .first(where: {
                $0.id.caseInsensitiveCompare(repoID) == .orderedSame
                    || $0.sourceRepoID.caseInsensitiveCompare(repoID) == .orderedSame
            })?.approxRAMBytes ?? 0))
        return requiredLoadBytes(peakBytes: max(measuredPeak, declaredPeak))
    }

    @MainActor
    static func canSafelyLoadVision(
        repoID: String,
        availableBytes: UInt64? = nil
    ) -> Bool {
        let available = availableBytes
            ?? UInt64(max(0, MemoryAdvisor.availableMemoryForModel))
        return available >= requiredVisionLoadBytes(repoID: repoID)
    }

    /// Extra GPU headroom for vision towers that force a large fixed
    /// resolution. Gemma 3/4 SigLIP always runs at 896² (~4096 patches);
    /// without this reserve the weight×1.6 gate green-lights a load that
    /// then jetsams mid-encode on ~6.2 GB process caps (iPhone 18,2).
    static nonisolated func visionActivationReserveBytes(repoID: String) -> UInt64 {
        let lower = repoID.lowercased()
        if lower.contains("bonsai-27b") {
            return UInt64(800_000_000)
        }
        if lower.contains("gemma-3") || lower.contains("gemma3")
            || lower.contains("gemma-4") || lower.contains("gemma4") {
            return UInt64(1_200_000_000)   // ~1.2 GB SigLIP @ 896²
        }
        return 0
    }

    /// Estimate the largest of two non-overlapping phases:
    ///
    /// - load: mmap/read/quantized-weight setup can transiently exceed weights
    /// - inference: steady weights coexist with the vision activation graph
    ///
    /// Adding the two phases together double-counts the weights and makes a
    /// supported high-resolution VLM appear impossible even when each phase
    /// independently fits under the allocator ceiling.
    static nonisolated func phaseAwarePeakBytes(
        weightBytes: UInt64,
        activationReserveBytes: UInt64
    ) -> UInt64 {
        let loadPeak = UInt64(Double(weightBytes) * MemoryAdvisor.loadSpikeMultiplier)
        let inferencePeak = weightBytes + activationReserveBytes
        return max(loadPeak, inferencePeak)
    }

    /// Peak model allocation plus space that must remain available to the app.
    /// Kept as one testable calculation so the runtime gate cannot drift back
    /// to comparing a model peak directly with all remaining process memory.
    static nonisolated func requiredLoadBytes(peakBytes: UInt64) -> UInt64 {
        peakBytes + UInt64(MemoryAdvisor.loadHeadroomReserve)
    }

    /// Cap MLX's allocator for a heavy VLM load/inference window so freed
    /// buffers return to iOS instead of stacking past the process ceiling.
    /// Mirrors ImageGenerationService's jetsam fix on the same device class.
    private static func withMLXMemoryCap<T>(
        cacheLimitBytes: Int,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let prevCache = MLX.Memory.cacheLimit
        let prevMem = MLX.Memory.memoryLimit
        let avail = max(0, MemoryAdvisor.availableMemoryForModel)
        let currentMLX = Int64(MLX.Memory.activeMemory) + Int64(MLX.Memory.cacheMemory)
        // memoryLimit is a TOTAL MLX allocation limit, not a remaining-headroom
        // limit. The old code set it to `available - cushion`; once model weights
        // were resident that could put the limit below activeMemory, causing MLX
        // allocation waits that never made progress (watchdog kill). Add current
        // MLX allocation back, then reserve ordinary app headroom.
        let additional = max(0, avail - MemoryAdvisor.loadHeadroomReserve)
        let limit = avail > 0
            ? max(1_024 * 1024 * 1024, currentMLX + additional)
            : 2_048 * 1024 * 1024
        MLX.Memory.memoryLimit = Int(limit)
        MLX.Memory.cacheLimit = max(0, cacheLimitBytes)
        defer {
            MLX.Memory.cacheLimit = prevCache
            MLX.Memory.memoryLimit = prevMem
        }
        return try await body()
    }

    // MARK: - Image helpers (ported from MLXVisionService)

    /// Strategy-aware sizing for the one-shot describe path. Picks
    /// the right approach based on the model's `inputSizingStrategy`
    /// and aims for `recommendedStillPixels` (larger than the
    /// streaming budget — describe() is latency-tolerant so we feed
    /// the model the highest-quality input the architecture accepts).
    ///
    /// Behavior per strategy:
    ///
    ///   • `.dynamicPatchAligned`  (Qwen2/2.5/3-VL):
    ///       Scale total pixels under `min(recommendedStillPixels,
    ///       maxPixels)`, then crop each dimension to a multiple of
    ///       `patch * merge`. Tiny inputs get upscaled to `minPixels`
    ///       first via Lanczos, then aligned. Lets the model see up
    ///       to ~1 megapixel for screen reading.
    ///
    ///   • `.fixed`  (LLaVA 1.5, Moondream, PaliGemma):
    ///       Scale long edge to `2 × target.width`. Processor's own
    ///       bicubic-to-square step does the final precise resize
    ///       from a clean intermediate.
    ///
    ///   • `.anyresTiling`  (LLaVA 1.6):
    ///       Scale long edge to `2 × baseSize`. Processor picks the
    ///       tile grid from its pinpoints based on aspect.
    ///
    ///   • `.fixedTiling`  (SmolVLM family — blocked by the
    ///       compatibility guard, this branch is unreachable in
    ///       current code but kept for correctness if a future
    ///       model uses fixed tiling without the upstream bug):
    ///       Fit long edge to `tile_size` (single-tile mode).
    ///
    /// nil-caps fallback: assume `.dynamicPatchAligned`-ish behavior
    /// with conservative ~512² pixel budget — better than no resize
    /// when the caps file failed to load.
    private static func sizedForStill(_ cg: CGImage, capabilities: VLMCapabilities?) -> CGImage {
        guard let caps = capabilities else {
            // No caps → conservative fit: long edge to 1024 px, no
            // alignment. Should never happen in production since
            // VLMCapabilities.load returns a default for unknown
            // architectures, but defensive.
            return fitToTileLongEdge(cg, tileSize: 1024)
        }

        switch caps.inputSizingStrategy {
        case .dynamicPatchAligned(let patch, let merge, let minPixels, let maxPixels):
            let cap = Swift.min(caps.recommendedStillPixels, maxPixels)
            let total = cg.width * cg.height
            // Three sub-cases:
            //   under both budget and minPixels  → upscale to minPixels floor
            //   under budget, over minPixels     → no scale
            //   over budget                      → downscale to cap
            let scaledIntermediate: CGImage
            if total > cap {
                let scale = (Double(cap) / Double(total)).squareRoot()
                scaledIntermediate = resampled(cg, scale: scale)
            } else if total < minPixels {
                let scale = (Double(minPixels) / Double(total)).squareRoot()
                scaledIntermediate = resampled(cg, scale: scale)
            } else {
                scaledIntermediate = cg
            }
            // Now crop each dimension to a multiple of patch*merge.
            return alignedToPatchGrid(scaledIntermediate, alignment: patch * merge, minPixels: minPixels)

        case .fixed(let target):
            let targetLong = 2 * Swift.max(Int(target.width), Int(target.height))
            return fitToTileLongEdge(cg, tileSize: targetLong)

        case .anyresTiling(let base, _):
            return fitToTileLongEdge(cg, tileSize: 2 * base)

        case .fixedTiling(let tile, _):
            // Defensive — should be unreachable behind the
            // isLensPipelineCompatible guard for all currently-known
            // fixedTiling models (SmolVLM family).
            return fitToTileLongEdge(cg, tileSize: tile)
        }
    }

    /// Crop both dimensions DOWN to a multiple of `alignment` (which
    /// is `patch * merge` for Qwen-VL). If the resulting pixel count
    /// would fall below `minPixels`, scale UP first and re-align.
    /// Mirrors `LensFramePreparer.alignedToPatchGrid` for CGImage.
    private static func alignedToPatchGrid(_ cg: CGImage, alignment: Int, minPixels: Int) -> CGImage {
        let w = cg.width, h = cg.height
        let alignedW = Swift.max(alignment, (w / alignment) * alignment)
        let alignedH = Swift.max(alignment, (h / alignment) * alignment)

        // Common case: aligned dims still satisfy minPixels.
        if alignedW * alignedH >= minPixels {
            if alignedW == w && alignedH == h { return cg }
            return cropped(cg, width: alignedW, height: alignedH)
        }

        // Floor case: alignment dropped us below minPixels — scale up
        // to where the aligned crop hits the floor, then realign.
        let scaleUp = (Double(minPixels) / Double(alignedW * alignedH)).squareRoot()
        let upscaled = resampled(cg, scale: scaleUp)
        let uw = upscaled.width, uh = upscaled.height
        let aw = Swift.max(alignment, (uw / alignment) * alignment)
        let ah = Swift.max(alignment, (uh / alignment) * alignment)
        return cropped(upscaled, width: aw, height: ah)
    }

    /// CG resample wrapper. Used by sizedForStill / alignedToPatchGrid.
    /// Returns the input unchanged for scale ≈ 1.
    private static func resampled(_ cg: CGImage, scale: Double) -> CGImage {
        guard scale > 0 else { return cg }
        let w = cg.width, h = cg.height
        let outW = Int((Double(w) * scale).rounded())
        let outH = Int((Double(h) * scale).rounded())
        if outW == w && outH == h { return cg }
        guard outW > 0, outH > 0 else { return cg }
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue |
                         CGImageByteOrderInfo.order32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? cg
    }

    /// Top-left aligned crop. Mirrors LensFramePreparer's CIImage crop
    /// — origin-anchored so the orientation step's effect on layout
    /// isn't shifted by an offset.
    private static func cropped(_ cg: CGImage, width: Int, height: Int) -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        return cg.cropping(to: rect) ?? cg
    }

    /// Aspect-preserved scale so the LONG edge equals `tileSize`.
    /// Scales UP or DOWN as needed — handles both pathologically
    /// small inputs (share-extension thumbnails) and oversize inputs
    /// (gallery photos) in one function.
    ///
    /// Why long edge, not short: for `.fixedTiling` models the
    /// processor's split decision is keyed on whether either
    /// dimension exceeds `max_image_size`. Keeping the long edge
    /// at `tileSize` (which ≤ max_image_size by construction for
    /// every architecture in the defaults table) guarantees
    /// single-tile mode and avoids the patch-count mismatch that
    /// crashes mlx-swift-examples' tile-aware code paths.
    ///
    /// Returns the input unchanged when it's already at exactly
    /// the target long edge — avoids a no-op render.
    private static func fitToTileLongEdge(_ cg: CGImage, tileSize: Int) -> CGImage {
        let w = cg.width, h = cg.height
        let longEdge = Swift.max(w, h)
        guard longEdge > 0, longEdge != tileSize else { return cg }
        let scale = Double(tileSize) / Double(longEdge)
        let outW = Int((Double(w) * scale).rounded())
        let outH = Int((Double(h) * scale).rounded())
        guard outW > 0, outH > 0 else { return cg }
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue |
                         CGImageByteOrderInfo.order32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? cg
    }

    /// Scale a CGImage up so its short side is at least `minSide`,
    /// preserving aspect. Kept as a defensive helper for callers
    /// that don't have `VLMCapabilities` available. The describe()
    /// path now uses `fitToTileLongEdge` instead — see the comment
    /// over that function for why.
    private static func upscaleIfTiny(_ cg: CGImage, minSide: Int) -> CGImage {
        let w = cg.width, h = cg.height
        let short = Swift.min(w, h)
        guard short < minSide, short > 0 else { return cg }
        let scale = Double(minSide) / Double(short)
        let outW = Int((Double(w) * scale).rounded())
        let outH = Int((Double(h) * scale).rounded())
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue |
                         CGImageByteOrderInfo.order32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: outW * 4,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? cg
    }

    /// Small UIImage thumbnail of the input the model saw, for the
    /// lens debug overlay.
    private static func thumbnail(from cg: CGImage, maxDim: CGFloat) -> UIImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(maxDim / w, maxDim / h, 1)
        if scale >= 1 { return UIImage(cgImage: cg) }
        let outW = Int(w * scale), outH = Int(h * scale)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bpr = outW * 4
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue |
                         CGImageByteOrderInfo.order32Little.rawValue
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: cs, bitmapInfo: bitmapInfo
        ) else { return UIImage(cgImage: cg) }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let scaled = ctx.makeImage() else { return UIImage(cgImage: cg) }
        return UIImage(cgImage: scaled)
    }

    /// Resize-hint side length passed to MLX-VLM's processor. Pulled
    /// from capabilities so the hint matches what the LensFrame-
    /// Preparer already produced — the processor's internal bicubic
    /// step then has a clean square intermediate to work with.
    /// `nonisolated` because it's pure computation called from inside
    /// `container.perform`'s @Sendable closure, which runs off the
    /// MainActor.
    nonisolated fileprivate static func resizeHintSide(for caps: VLMCapabilities) -> Int {
        switch caps.inputSizingStrategy {
        case .fixed(let s):
            return Int(max(s.width, s.height))
        case .dynamicPatchAligned(_, _, _, _):
            return Int(Double(caps.recommendedStreamingPixels).squareRoot().rounded())
        case .anyresTiling(let base, _):
            return base
        case .fixedTiling(let tile, _):
            return tile
        }
    }
}
