import Foundation
import UIKit
import Combine

// MARK: - Per-family execution policy

/// Lens requests are short, single-image turns. Large VLMs should not inherit
/// a desktop-chat context allocation just because llama.cpp defaults to one.
/// Keeping this policy explicit lets every catalog family select the smallest
/// safe context without special-casing the C++ bridge itself.
struct LlamaCppVLMExecutionProfile: Equatable, Sendable {
    let contextSize: UInt32
    let maxOutputTokens: Int
    let requiresSingleResidency: Bool

    static func resolve(repoID: String) -> Self {
        let id = repoID.lowercased()
        if id.contains("gemma-3") || id.contains("gemma3") {
            // Gemma 3 expands one image to 256 soft tokens. A 1K context still
            // leaves ample room for the Lens prompt + 192-token answer while
            // avoiding the multi-GB KV allocation a desktop-style 4K context
            // can create for a 4B model.
            return .init(
                contextSize: 1_024,
                maxOutputTokens: 192,
                requiresSingleResidency: true
            )
        }
        return .init(
            contextSize: 4_096,
            maxOutputTokens: 256,
            requiresSingleResidency: false
        )
    }
}

// MARK: - LlamaCppVLMService
//
// Parallel to LensInferenceLoop, but for GGUF-format VLMs running
// through llama.cpp + mtmd instead of MLX. The lens tab routes
// to this service when the active visual model is a GGUF file
// (detected by repoID containing "GGUF" or by the on-disk file
// extension); routes to LensInferenceLoop otherwise.
//
// State machine matches LensInferenceLoop's so the UI bindings
// in ContentView / ModelsManagerView can switch backends without
// caring which one is active.
//
// Memory ownership: one `LlamaCppVLM` at a time. Switching to a
// different GGUF repo unloads the previous one before loading the
// new one. Tab and backend switches always drain the inactive runtime;
// static dual-residence estimates are not trusted for Metal handoffs.
//
// Threading: @MainActor for state + lifecycle. The actual llama.cpp
// inference runs on a Task.detached at .userInitiated priority,
// since llama.cpp blocks Metal command queues during decode and
// hopping back to MainActor mid-token would be wasteful.

@MainActor
final class LlamaCppVLMService: ObservableObject {

    static let shared = LlamaCppVLMService()

    // MARK: - State (parallel to LensInferenceLoop.State)

    enum State: Equatable {
        case unloaded
        case loading(String)       // progress message
        case ready
        case generating
        case failed(String)
    }

    @Published private(set) var state: State = .unloaded

    /// Repo ID currently loaded (e.g. "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF").
    /// nil when no model is loaded.
    @Published private(set) var activeRepoID: String?

    /// Display name pulled from the repo ID's tail. Surface for the
    /// debug overlay and the active-model pill.
    @Published private(set) var modelDisplayName: String = ""

    /// Last-inference metrics for the debug overlay. Parallels the
    /// fields on LensInferenceLoop.
    @Published private(set) var lastInferenceMillis: Double = 0
    @Published private(set) var lastTokensPerSecond: Double = 0
    @Published private(set) var lastModelInput: UIImage?

    // MARK: - Internal state

    private var vlm: LlamaCppVLM?
    private var inferenceTask: Task<Void, Never>?
    /// Native model construction is not cooperatively cancellable once
    /// llama.cpp enters C++. Retain the task so a backend/tab handoff can wait
    /// for construction to finish and release its result before starting a
    /// different Metal runtime.
    private var loadingTask: Task<LlamaCppVLM, Error>?
    private var loadingTaskID: UUID?
    private var loadingRepoID: String?
    private var loadingTransitionID: UUID?

    /// Observer for the memory-pressure cache-drop broadcast. Held for
    /// the singleton's (process-long) lifetime, never removed.
    private var dropCachesObserver: NSObjectProtocol?

    private init() {
        // Drop the debug-overlay thumbnail on memory pressure — it holds a
        // full-resolution UIImage of the last input, which is pure
        // discardable cache when MemoryPressureCoordinator posts
        // .codeLensDropDiscardableCaches.
        dropCachesObserver = NotificationCenter.default.addObserver(
            forName: .codeLensDropDiscardableCaches,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lastModelInput = nil
            }
        }
    }

    // MARK: - File-layout convention
    //
    // GGUF VLMs ship as a PAIR of files in the same directory:
    //   <repo>/
    //     SmolVLM2-500M-Video-Instruct-Q8_0.gguf       (LLM)
    //     mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf (vision projector)
    //
    // ggml-org's convention is `mmproj-*` for the projector. We
    // resolve the pair via filename prefix.

    /// Returns the on-disk directory for `repoID` if both the LLM
    /// and mmproj files exist. nil if not staged yet.
    nonisolated static func stagedDirectory(for repoID: String) -> URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let flattened = repoID.replacingOccurrences(of: "/", with: "_")
        let candidates: [URL] = [
            docs.appendingPathComponent("HFModels").appendingPathComponent(repoID),
            docs.appendingPathComponent("HFModels").appendingPathComponent(flattened),
            docs.appendingPathComponent("GGUFModels").appendingPathComponent(flattened),
        ]
        for dir in candidates {
            if hasGGUFPair(in: dir) { return dir }
        }
        return nil
    }

    /// True when `dir` contains at least one `*.gguf` (the LLM) AND
    /// at least one `mmproj-*.gguf` (the projector).
    private nonisolated static func hasGGUFPair(in dir: URL) -> Bool {
        LocalModelFileValidator.hasCompleteGGUFVLMPair(in: dir)
    }

    /// Resolve the LLM .gguf path inside `dir`. Delegates to the validator's
    /// recursive, case-insensitive finder so the loader agrees with the
    /// readiness probe (`hasCompleteGGUFVLMPair`) — see `ggufLLM`.
    nonisolated static func resolveLLMPath(in dir: URL) -> String? {
        LocalModelFileValidator.ggufLLM(in: dir)?.path
    }

    /// Resolve the mmproj .gguf path inside `dir`. Same recursive,
    /// case-insensitive source of truth as the probe — see `ggufProjector`.
    nonisolated static func resolveMmprojPath(in dir: URL) -> String? {
        LocalModelFileValidator.ggufProjector(in: dir)?.path
    }

    // MARK: - Memory estimate
    //
    // For the ModelResidency dual-residence math. Sums actual file
    // sizes on disk when staged; falls back to a conservative 600 MB
    // estimate (covers SmolVLM2-500M-Q8 + mmproj-Q8 at ~520 MB, with
    // a bit of headroom).

    nonisolated static func estimatedWeightBytes(repoID: String) -> UInt64 {
        if let dir = stagedDirectory(for: repoID) {
            let total = sumGGUFFiles(in: dir)
            if total > 0 { return total }
        }
        return UInt64(600 * 1024 * 1024)
    }

    private nonisolated static func sumGGUFFiles(in dir: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".gguf") else { continue }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    // MARK: - Load / unload

    /// Switch to `repoID`. Idempotent — same-repo calls return
    /// immediately. Different-repo calls unload the current model
    /// first. Concurrent calls on the same repoID are guarded via
    /// `loadingRepoID` (same pattern as LensInferenceLoop.switchTo).
    func switchTo(repoID: String) async {
        // Claim the transition before the first await. A same- or different-
        // repo request arriving during native teardown/load must not enter a
        // second constructor and stack two GGUF models in memory.
        if let loadingRepoID {
            let loadingName = loadingRepoID.split(separator: "/").last.map(String.init)
                ?? loadingRepoID
            ToastCenter.shared.info("Model already loading",
                                     detail: "Please wait for \(loadingName) to finish.")
            return
        }
        let transitionID = UUID()
        loadingRepoID = repoID
        loadingTransitionID = transitionID
        defer {
            if loadingTransitionID == transitionID {
                loadingRepoID = nil
                loadingTransitionID = nil
            }
        }

        if activeRepoID == repoID, vlm != nil {
            // A resident Lens model still owns the device exclusively. Returning
            // to it from Assistant must drain the chat/MLX runtimes first.
            await CodingAssistantService.shared.unloadAndWaitForCleanup()
            MLXVisionService.shared.unload()
            FastVLMService.shared.unload()
            await MLXGenerationGate.shared.clearCacheWhenIdle()
            guard loadingTransitionID == transitionID,
                  activeRepoID == repoID,
                  vlm != nil else { return }
            state = .ready
            return
        }

        // Drain this backend, then every competing backend, before native
        // model construction. llama.cpp/mtmd does not share MLXGenerationGate,
        // so merely cancelling an MLX task is not enough to prevent overlap.
        await unloadForModelSwitch()
        await CodingAssistantService.shared.unloadAndWaitForCleanup()
        MLXVisionService.shared.unload()
        FastVLMService.shared.unload()
        await MLXGenerationGate.shared.clearCacheWhenIdle()

        guard let dir = Self.stagedDirectory(for: repoID) else {
            state = .failed("GGUF files not found on disk for \(repoID). Download from the Catalog first.")
            return
        }
        guard let llmPath = Self.resolveLLMPath(in: dir),
              let mmprojPath = Self.resolveMmprojPath(in: dir) else {
            state = .failed("Couldn't find LLM and mmproj GGUF files in \(dir.path).")
            return
        }

        let shortName = repoID.split(separator: "/").last.map(String.init) ?? repoID
        let profile = LlamaCppVLMExecutionProfile.resolve(repoID: repoID)

        // Memory gate — mirror of LensInferenceLoop.switchTo's pre-flight.
        // GGUF loads offload everything Metal accepts (n_gpu_layers = 999)
        // with no other check, so refuse when the estimated load peak
        // exceeds the live per-process headroom. Recovery first: unload
        // the chat LLM (the cross-tab model) and re-measure before
        // giving up.
        let estimated = Self.estimatedWeightBytes(repoID: repoID)
        let peak = Int64(Double(estimated) * MemoryAdvisor.loadSpikeMultiplier)
        let needed = peak + MemoryAdvisor.loadHeadroomReserve

        var available = MemoryAdvisor.availableMemoryForModel
        Diagnostics.shared.breadcrumb(
            "GGUF VLM preflight · \(repoID) · context=\(profile.contextSize) · peak=\(peak.formattedBytes) · required=\(needed.formattedBytes) · available=\(available.formattedBytes)",
            category: "lens"
        )
        if available < needed {
            await CodingAssistantService.shared.unloadAndWaitForCleanup()
            // The kernel's accounting can lag the teardown — poll briefly
            // instead of trusting one read.
            for _ in 0..<10 {
                available = MemoryAdvisor.availableMemoryForModel
                if available >= needed { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if available < needed {
            state = .failed(String(format:
                "Not enough memory to load this model. Need ~%.0f MB, have %.0f MB available. Close other apps and try again.",
                Double(needed) / 1_048_576, Double(available) / 1_048_576))
            return
        }

        state = .loading("Preparing \(shortName)…")

        // Off the MainActor — model load is heavy I/O + Metal warmup.
        let loaded: LlamaCppVLM
        let taskID = transitionID
        do {
            let task = Task.detached(priority: .userInitiated) {
                try LlamaCppVLM(
                    llmPath: llmPath,
                    mmprojPath: mmprojPath,
                    contextSize: profile.contextSize
                )
            }
            loadingTask = task
            loadingTaskID = taskID
            loaded = try await task.value
            if loadingTaskID == taskID {
                loadingTask = nil
                loadingTaskID = nil
            }
        } catch {
            if loadingTaskID == taskID {
                loadingTask = nil
                loadingTaskID = nil
            }
            guard loadingTransitionID == transitionID else {
                return
            }
            state = .failed(error.localizedDescription)
            ToastCenter.shared.error("Vision model failed to load",
                                      detail: error.localizedDescription)
            return
        }

        // Superseded mid-flight (a later switchTo or unload changed the
        // expected repo) — drop this load instead of clobbering the newer
        // one; `loaded`'s deinit frees the weights.
        guard loadingTransitionID == transitionID else { return }

        self.vlm = loaded
        self.activeRepoID = repoID
        self.modelDisplayName = shortName
        state = .ready
        Diagnostics.shared.notice(
            "GGUF VLM ready · \(shortName) · context=\(profile.contextSize) · footprint=\(MemoryAdvisor.physFootprint.formattedBytes)",
            category: "lens"
        )
        ToastCenter.shared.success("Vision model ready", detail: shortName)
    }

    /// Tear down the current VLM. Cancels any in-flight inference
    /// first so its closures aren't called after we've freed state.
    func unload() {
        loadingRepoID = nil
        loadingTransitionID = nil
        let load = loadingTask
        let inference = inferenceTask
        load?.cancel()
        inference?.cancel()
        vlm?.cancelCurrent()
        vlm = nil
        activeRepoID = nil
        modelDisplayName = ""
        state = .unloaded
    }

    /// Deterministic backend handoff. Native llama.cpp construction/decode may
    /// continue briefly after Swift cancellation, so wait for both tasks before
    /// another model runtime is allowed to allocate Metal resources.
    func unloadAndWaitForCleanup() async {
        loadingRepoID = nil
        loadingTransitionID = nil
        let load = loadingTask
        let inference = inferenceTask
        loadingTask = nil
        loadingTaskID = nil
        inferenceTask = nil
        load?.cancel()
        inference?.cancel()
        vlm?.cancelCurrent()
        vlm = nil
        activeRepoID = nil
        modelDisplayName = ""
        state = .unloaded
        if let load { _ = try? await load.value }
        _ = await inference?.value
        autoreleasepool { }
    }

    /// Same-backend switch teardown that preserves the transition latch owned
    /// by `switchTo` while waiting for the old decode to release its captures.
    private func unloadForModelSwitch() async {
        let load = loadingTask
        let inference = inferenceTask
        loadingTask = nil
        loadingTaskID = nil
        inferenceTask = nil
        load?.cancel()
        inference?.cancel()
        vlm?.cancelCurrent()
        vlm = nil
        activeRepoID = nil
        modelDisplayName = ""
        state = .unloaded
        if let load { _ = try? await load.value }
        _ = await inference?.value
        autoreleasepool { }
    }

    /// Cancel any in-flight inference without unloading.
    func cancelCurrentInference() {
        inferenceTask?.cancel()
        vlm?.cancelCurrent()
        // Keep state/task latched until native decode really exits. Marking
        // `.ready` here allowed a foreground retry to enter while the cancelled
        // llama.cpp Metal work was still unwinding.
    }

    // MARK: - Describe (one-shot inference)

    /// Stream a caption / answer for `image` and `prompt`. Mirrors
    /// LensInferenceLoop.describe's signature exactly so callers
    /// (AnalysisService.tryMLXVisionPath, etc.) can dispatch by
    /// backend without per-call shape differences.
    func describe(
        image: UIImage,
        prompt: String = "Describe what's in this image. Be concise.",
        maxTokens: Int = 256,
        onToken: @Sendable @escaping (String) -> Void,
        onComplete: @Sendable @escaping (Double) -> Void
    ) {
        guard case .ready = state, let vlm = vlm else {
            onComplete(0)
            return
        }

        // Thermal/memory + background safety gates — same as the MLX path
        // (LensInferenceLoop.describe). Submitting llama.cpp Metal work while
        // backgrounding (the common scene-transition lens path) hits
        // kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted,
        // which aborts the process. Reading applicationState is safe: this
        // type is @MainActor.
        if DeviceSafetyMonitor.shared.shouldStopHeavyWork
            || UIApplication.shared.applicationState != .active {
            onComplete(0)
            return
        }

        // Capture the image thumbnail for the debug overlay.
        self.lastModelInput = image

        let profile = LlamaCppVLMExecutionProfile.resolve(repoID: activeRepoID ?? "")
        let tokenCap = min(
            maxTokens,
            profile.maxOutputTokens,
            DeviceSafetyMonitor.shared.recommendedMaxTokens
        )

        state = .generating
        let startedAt = Date()
        let footprintBefore = MemoryAdvisor.physFootprint
        ModelResidency.shared.cancelPrefetch()

        inferenceTask?.cancel()
        // Fire-once wrapper around the caller's onComplete. The
        // bridge's documented contract is "either onComplete is
        // called OR an error is thrown, never both" — but if a
        // future change ever violates that, the wrapper keeps the
        // caller's continuation safe (AnalysisService.tryLlamaCppVisionPath
        // resumes a CheckedContinuation from here and would crash
        // on a double-fire).
        let completionGuard = CompletionGuard(onComplete)
        inferenceTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try vlm.describe(
                    image: image,
                    prompt: prompt,
                    maxTokens: tokenCap,
                    onToken: { token in
                        onToken(token)
                    },
                    onComplete: { rate in
                        Task { @MainActor in
                            self?.lastTokensPerSecond = rate
                            self?.lastInferenceMillis = Date().timeIntervalSince(startedAt) * 1000
                            self?.inferenceTask = nil
                            // Restore .ready only if still generating —
                            // unload() may have torn the model down
                            // mid-flight, and flipping back to .ready
                            // would show "ready" with nothing loaded.
                            if case .generating = self?.state { self?.state = .ready }
                            ModelResidency.shared.schedulePrefetch(currentTab: .lens)
                            // Persist per-model avg tok/s so the picker can
                            // surface a perf pill alongside the install /
                            // RAM badges. tokens=0 because mtmd doesn't
                            // report a per-run count here; avgTPS is the
                            // only field the picker reads.
                            if let id = self?.activeRepoID, rate > 0 {
                                ModelUsageTracker.shared.recordGeneration(
                                    modelID: id, tokens: 0, tokensPerSecond: rate
                                )
                            }
                            let footprintAfter = MemoryAdvisor.physFootprint
                            Diagnostics.shared.breadcrumb(
                                "GGUF VLM inference · context=\(profile.contextSize) · tokens≤\(tokenCap) · footprint \(footprintBefore.formattedBytes) → \(footprintAfter.formattedBytes)",
                                category: "lens"
                            )
                        }
                        completionGuard.fire(rate)
                    }
                )
            } catch is CancellationError {
                Task { @MainActor in
                    self?.inferenceTask = nil
                    if case .generating = self?.state { self?.state = .ready }
                }
                completionGuard.fire(0)
            } catch let llamaErr as LlamaCppError where llamaErr == LlamaCppError.cancelled {
                Task { @MainActor in
                    self?.inferenceTask = nil
                    if case .generating = self?.state { self?.state = .ready }
                }
                completionGuard.fire(0)
            } catch {
                Task { @MainActor in
                    self?.inferenceTask = nil
                    self?.state = .failed(error.localizedDescription)
                    ToastCenter.shared.error("Inference failed",
                                              detail: error.localizedDescription)
                }
                completionGuard.fire(0)
            }
        }
    }
}

// MARK: - CompletionGuard
//
// Lock-protected single-shot wrapper. The caller's onComplete is
// guaranteed to fire exactly once regardless of which code path
// (bridge success, bridge cancel-throw, catch-all, etc.) tries
// to invoke it. Subsequent calls are silently dropped.
//
// Defensive layer for the AnalysisService continuation, which
// crashes hard on a second `cont.resume()`.

private final class CompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let body: @Sendable (Double) -> Void

    init(_ body: @escaping @Sendable (Double) -> Void) {
        self.body = body
    }

    func fire(_ rate: Double) {
        lock.lock()
        let alreadyFired = fired
        fired = true
        lock.unlock()
        guard !alreadyFired else { return }
        body(rate)
    }
}

// Equatable conformance for LlamaCppError lives in
// LlamaCppBridge.swift (it's declared alongside the error type
// itself there). Don't duplicate it here.
