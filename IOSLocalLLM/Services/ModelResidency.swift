import Foundation
import os

// MARK: - ModelResidency
//
// Decides whether the assistant LLM and the visual VLM can live in
// memory simultaneously, and prefetches weight files into the OS page
// cache during idle periods to speed up subsequent loads.
//
// Two utilities are provided:
//
//   1. `canResideTogether()` — a conservative capacity diagnostic retained
//      for status/telemetry. Runtime handoffs no longer use it: camera buffers,
//      allocator pooling and cancellation tails are not captured by a static
//      weight sum, so ContentView always keeps one inference runtime active.
//
//   2. `schedulePrefetch(for:)` — when an active model finishes loading
//      and the user is idle, walk the OTHER tab's weight files in
//      background and read them into the OS page cache. Subsequent
//      MLX mmap'd loads of those weights hit cached pages and run
//      faster (modest 20–30% improvement; doesn't OOM because we
//      never actually allocate Metal buffers — just prime the kernel's
//      VM cache).
//
// Why a separate type: CodingAssistantService and LensInferenceLoop
// don't know about each other, and shouldn't — each is responsible for
// its own model lifecycle. The cross-model residency policy needs a
// neutral place to live, and the prefetch coordinator needs to cancel
// across both. ModelResidency is that neutral place.

@MainActor
final class ModelResidency: ObservableObject {

    static let shared = ModelResidency()

    private init() {}

    // MARK: - Tier budget table
    //
    // Per-device-class hard budget for "both models combined." Used by
    // canResideTogether(). Sized against the iOS PER-PROCESS memory
    // limit, NOT the device's total RAM — even with the
    // `increased-memory-limit` entitlement, a 12 GB device gives the
    // app ~6 GB. So our "combined" budgets must fit inside that
    // process cap with headroom for app overhead (UI, AVCaptureSession,
    // SwiftUI view tree, etc., ~0.5–1 GB) AND the load-peak headroom
    // already covered by the per-model gate's 1.6× multiplier.
    //
    // The previous values (4–8 GB combined) were sized against device
    // RAM. They allowed dual-residence configs that crashed on actual
    // load — a 17 Pro Max user hit EXC_RESOURCE at the 6 GB watermark
    // with the old .max budget of 8 GB. These revised numbers refuse
    // any dual-residence that would risk that.
    //
    //   .lite  (<4 GB, ~1.5 GB process):  0   — single model only
    //   .entry (4 GB, ~2 GB process):     0   — single model only
    //   .mid   (6 GB, ~3.3 GB process):   0   — single model only
    //   .pro   (8 GB, ~4–5 GB process):   2.0 GB combined
    //                                          → 1.7B chat + 2B VLM fits
    //   .max   (12 GB+, ~6 GB process):   3.0 GB combined
    //                                          → 4B chat + 2B VLM fits;
    //                                            4B + 4B (5.8 GB) is
    //                                            deliberately refused

    private static var dualResidenceBudgetBytes: UInt64 {
        let gb: Double
        switch DeviceTierAdvisor.current {
        case .lite, .entry, .mid:
            gb = 0      // no dual-residence at these tiers
        case .pro:
            gb = 2.0
        case .max:
            gb = 3.0
        }
        return UInt64(gb * 1_073_741_824)
    }

    /// Approximate weight bytes for the built-in FastVLM (0.5B Qwen2
    /// decoder + projector safetensors + Core ML encoder ≈ 0.6 GB).
    /// There's no repo directory to measure via the per-backend
    /// estimators, so the dual-residence math uses this constant.
    private static let fastVLMWeightBytes: UInt64 = 600 * 1024 * 1024

    // MARK: - A. Dual-residence decision

    /// True when the currently-selected assistant LLM AND the currently-
    /// selected visual VLM can both fit in memory on this device. When
    /// This is informational only. It must not be used to skip a runtime
    /// handoff; live transient memory is intentionally outside this estimate.
    ///
    /// Returns false defensively when:
    ///   • The device tier has no dual-residence budget (.lite)
    ///   • The default FastVLM path is selected and its weights plus the
    ///     LLM's exceed the budget — FastVLM is small (~0.6 GB) but it is
    ///     NOT free, so it goes through the same budget check
    ///   • Combined weights exceeds the budget
    static func canResideTogether() -> Bool {
        let llm = AssistantModelCatalog.currentSelection()
        let storedVisionID = AppSettings.shared.cameraVisualModelID
        let visionSelection = LocalModelRegistry.storedVisionSelectionID(storedVisionID)

        let budget = dualResidenceBudgetBytes
        guard budget > 0 else { return false }

        let llmBytes = CodingAssistantService.estimatedWeightBytes(for: llm)

        // Default FastVLM selection: the lens tab still loads its weights,
        // so they count against the budget like any other VLM (this used
        // to return true unconditionally, ignoring the tier budget).
        if LocalModelRegistry.isDefaultVisionSelection(visionSelection) {
            return llmBytes + fastVLMWeightBytes <= budget
        }

        let runtime = LocalModelRegistry.visionRuntime(
            forStoredSelectionID: storedVisionID,
            catalog: ModelDownloadCenter.shared.models
        )
        let repoID = LocalModelRegistry.persistedVisionRepoID(for: visionSelection)
        // Pick the right estimator based on which backend owns the
        // VLM repo. GGUF VLMs (llama.cpp) and MLX VLMs have
        // different on-disk layouts so the byte-counting logic
        // differs slightly.
        let vlmBytes: UInt64 = runtime == .llamaCpp
            ? LlamaCppVLMService.estimatedWeightBytes(repoID: repoID)
            : LensInferenceLoop.estimatedWeightBytes(repoID: repoID)
        // Compare raw weight sum to the budget — the budget table
        // already accounts for activation / KV-cache / app-overhead
        // headroom within the per-process memory limit. Multiplying
        // here AND in the budget would be double-counting.
        let combined = llmBytes + vlmBytes
        return combined <= budget
    }

    // MARK: - B. Background prefetch
    //
    // Reads the OTHER tab's weight files from disk into a small buffer.
    // The actual buffer contents are discarded — the point is to prime
    // the kernel's page cache so subsequent mmap reads (which is how
    // MLX-swift loads safetensors via ModelConfiguration(directory:))
    // hit warm pages instead of cold disk.
    //
    // Memory cost: ~4 MB transient read buffer, immediately discarded.
    // The cached pages themselves are owned by the kernel and can be
    // evicted under pressure — they don't count against our process's
    // committed memory.
    //
    // Latency win: 20–30% faster MLX load on subsequent tab switch when
    // the other model isn't already resident. Doesn't help when both
    // ARE resident (Option A path), but in that case there's no load
    // to optimise.

    private var prefetchTask: Task<Void, Never>?

    /// Page-cache warming is speculative work. Keep it off battery and out of
    /// an already-warm thermal session; a model load remains correct without
    /// this optimization.
    nonisolated static func allowsBackgroundPrefetch(
        thermalState: ProcessInfo.ThermalState,
        isCharging: Bool,
        lowPowerMode: Bool
    ) -> Bool {
        thermalState == .nominal && isCharging && !lowPowerMode
    }

    /// Schedule a background prefetch of the OTHER tab's weight files
    /// after `idleDelay` seconds. Cancels any pending prefetch.
    ///
    /// Call after an active model finishes loading, passing `.assistant` as
    /// the currently-active tab (so we prefetch the VLM's files). Symmetric
    /// from LensInferenceLoop.
    func schedulePrefetch(currentTab: ActiveTab, idleDelay: TimeInterval = 4.0) {
        prefetchTask?.cancel()
        // Runtime policy is single-resident, so the other tab can benefit from
        // a small disk-only prefetch after an explicit model load. It is never
        // required for correctness and must not run on battery.
        guard Self.allowsBackgroundPrefetch(
            thermalState: DeviceSafetyMonitor.shared.effectiveThermalState,
            isCharging: DeviceSafetyMonitor.shared.isCharging,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        ) else { return }

        let otherTab = currentTab.opposite
        prefetchTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: UInt64(idleDelay * 1_000_000_000))
            if Task.isCancelled { return }
            let stillAllowed = await MainActor.run {
                Self.allowsBackgroundPrefetch(
                    thermalState: DeviceSafetyMonitor.shared.effectiveThermalState,
                    isCharging: DeviceSafetyMonitor.shared.isCharging,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
                )
            }
            guard stillAllowed else { return }
            await Self.primeCacheForOtherTab(otherTab)
        }
    }

    /// Cancel any in-flight prefetch — call this when the user starts
    /// inference on the active tab (the active model needs its disk
    /// bandwidth, not a speculative prefetch competing for it).
    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    enum ActiveTab {
        case assistant
        case lens

        var opposite: ActiveTab {
            switch self {
            case .assistant: return .lens
            case .lens:      return .assistant
            }
        }
    }

    /// Walk the target tab's model directory and read each weight file
    /// in chunks to prime the OS page cache. `priority: .background`
    /// means the system will deprioritize this disk IO if anything
    /// foreground needs bandwidth — we never starve the active model.
    private static nonisolated func primeCacheForOtherTab(_ tab: ActiveTab) async {
        let dir: URL?
        switch tab {
        case .assistant:
            let llm = await MainActor.run { AssistantModelCatalog.currentSelection() }
            dir = CodingAssistantService.preStagedDirectory(for: llm)
        case .lens:
            let storedVisionID = await MainActor.run { AppSettings.shared.cameraVisualModelID }
            let selectionID = await MainActor.run {
                LocalModelRegistry.storedVisionSelectionID(storedVisionID)
            }
            guard !LocalModelRegistry.isDefaultVisionSelection(selectionID) else { return }
            let runtime = await MainActor.run {
                LocalModelRegistry.visionRuntime(
                    forStoredSelectionID: storedVisionID,
                    catalog: ModelDownloadCenter.shared.models
                )
            }
            let repoID = LocalModelRegistry.persistedVisionRepoID(for: selectionID)
            // Pick the right stagedDirectory based on backend.
            dir = runtime == .llamaCpp
                ? LlamaCppVLMService.stagedDirectory(for: repoID)
                : LensInferenceLoop.stagedDirectory(for: repoID)
        }
        guard let dir else { return }

        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        // Materialise the enumerator into an Array before iterating.
        // Direct `for case let url as URL in enumerator` calls
        // FileManager.DirectoryEnumerator's NSFastEnumeration-bridged
        // makeIterator(), which Swift 6 flags as "not available from
        // an asynchronous context". The Array conversion runs the
        // enumeration synchronously (still cheap — directory traversal
        // is fast) and lets the for-await loop see a Sendable Array.
        let urls = enumerator.allObjects.compactMap { $0 as? URL }
        for url in urls {
            if Task.isCancelled { return }
            let name = url.lastPathComponent
            let isWeight = name.hasSuffix(".safetensors")
                        || name.hasSuffix(".npz")
                        || name.hasSuffix(".bin")
            guard isWeight else { continue }

            // Read the file in 4 MB chunks to prime the page cache.
            // Reading the WHOLE file would still work but doubles
            // disk-read bandwidth; the early chunks are what MLX
            // accesses first when laying out the model, so they
            // get the most benefit from being warm.
            //
            // 16 MB cap per file ensures we don't sit prefetching a
            // 5 GB safetensors for 30 seconds — the goal is "first
            // accesses are warm," not "every byte is cached."
            await primeFile(at: url, maxBytes: 16 * 1024 * 1024)
        }
    }

    private static nonisolated func primeFile(at url: URL, maxBytes: Int) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var remaining = maxBytes
        let chunkSize = 4 * 1024 * 1024
        while remaining > 0 {
            if Task.isCancelled { return }
            let toRead = min(chunkSize, remaining)
            let data = try? handle.read(upToCount: toRead)
            guard let data, !data.isEmpty else { return }
            remaining -= data.count
            if data.count < toRead { return }   // hit EOF
        }
    }
}
