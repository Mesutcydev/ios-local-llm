import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - MemoryAdvisor
// Helps decide whether loading a given model is safe on the current device.
//
// We use ProcessInfo.physicalMemory as the headline number, but reserve
// roughly 30% for the OS + foreground apps. Models that exceed the remaining
// budget are flagged as "won't fit" — the UI can warn before load() is called.
//
// The numbers below are approximate working-set sizes during inference, not
// raw weight sizes. A 4-bit Qwen3-4B has ~2.3 GB of weights but typically
// peaks around 3.5–4 GB with the KV cache.

enum MemoryAdvisor {

    // MARK: - Load-time headroom
    //
    // `estimatedFootprint(for:)` returns a model's *peak* resident working set
    // — steady-state weights + KV cache + activations + the transient during
    // load (on-disk read, 4-bit unpack, Metal upload running concurrently).
    // The gate (`safetyBlocker`) therefore compares that peak directly against
    // the live per-process ceiling and adds only a small fixed reserve for
    // app/OS glue. It must NOT multiply the footprint again — doing so was the
    // "everything reports double the RAM it needs" bug: a downloaded model was
    // sized at on-disk × `workingSetOverhead` inside `estimatedFootprint` and
    // then multiplied a *second* time by the spike factor here, yielding
    // on-disk × ~2.5 and refusing 4B/8B models that comfortably fit.
    //
    // `loadSpikeMultiplier` is the single weights→peak factor used by callers
    // that start from *raw* weight bytes (e.g. `LensInferenceLoop`, which sizes
    // the VLM from `estimatedWeightBytes`). It is applied exactly once on that
    // path. Inside this type, `estimatedFootprint` already bakes the peak in.
    static let loadSpikeMultiplier = 1.6

    // Single weights→peak factor for models sized from their on-disk weights
    // (downloaded / imported). On-disk size ≈ quantized weights; the resident
    // peak adds KV cache + activations. 1.3× covers a typical context window
    // for 4-bit/8-bit MLX models, which mmap their weights (the on-disk read
    // does not add resident pages beyond the weights themselves).
    static let workingSetOverhead = 1.3

    // Fixed headroom reserved on top of a model's estimated peak, covering the
    // app's own baseline, the MLX/Metal runtime, and OS glue. A fixed reserve
    // (rather than a percentage of model size) avoids over-penalizing large
    // models — the transient is already inside the peak estimate.
    static let loadHeadroomReserve: Int64 = 500_000_000

    // Reserve used in edge / developer mode (`AppSettings.showEdgeModels`).
    // Zero so a "tight" model whose peak just fits the live ceiling is allowed
    // to load. This is the opt-in risky path; the normal path keeps the full
    // `loadHeadroomReserve` and therefore can never be coaxed into an OOM.
    static let edgeHeadroomReserve: Int64 = 0

    // Conservative footprint assumed when a model can't be sized (custom /
    // imported repos with no preset match and no readable on-disk folder).
    // 3.5 GB covers an unknown mid/large model; with `loadHeadroomReserve` an
    // unsized model needs ~4 GB free to load — strict, since "we don't know
    // its size" should fail safe, but no longer wildly over-stated.
    static let unknownFootprintFloor: Int64 = 3_500_000_000

    // MARK: - Post-pressure load cooldown
    //
    // After the kernel reports CRITICAL memory pressure, MemoryPressureCoordinator
    // dumps model weights. For a short window afterward we refuse new HEAVY
    // loads: reloading immediately races iOS while it is still reclaiming, which
    // leaves the dumped model AND its reload both resident for a moment — the
    // exact spike that gets the process Jetsam-killed. Small recovery models
    // that comfortably fit current headroom are still allowed so the user is
    // never fully stuck.

    static let pressureCooldown: TimeInterval = 20
    /// A model at/under this peak may still load during the cooldown if it fits
    /// the live headroom — lets a small camera VLM recover the lens immediately.
    static let smallRecoveryModelCeiling: Int64 = 1_073_741_824   // 1 GB

    /// When set and in the future, heavy loads are on cooldown. MainActor-only;
    /// written by `notePressureDump()` and read by `safetyBlocker()`.
    @MainActor private(set) static var pressureLoadBlockedUntil: Date?

    /// Open the post-pressure cooldown. Called after an emergency weight dump.
    @MainActor static func notePressureDump() {
        pressureLoadBlockedUntil = Date().addingTimeInterval(pressureCooldown)
    }

    /// Seconds remaining on the post-critical-pressure cooldown, or nil when
    /// no cooldown is active. Single home for the date math so `safetyBlocker`
    /// and the VLM load gates (LensInferenceLoop.switchTo) enforce the same
    /// window — a heavy VLM reload must not race the kernel's reclaim either.
    @MainActor static var pressureCooldownRemaining: TimeInterval? {
        guard let until = pressureLoadBlockedUntil, until.timeIntervalSinceNow > 0 else {
            return nil
        }
        return until.timeIntervalSinceNow
    }

    // MARK: - Device

    /// Total physical RAM in bytes.
    static var deviceTotalRAM: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// RAM available for app use after a 30% headroom for OS + other apps.
    static var availableRAM: Int64 {
        Int64(Double(deviceTotalRAM) * 0.70)
    }

    /// Live per-process memory headroom in bytes — how much more this app can
    /// allocate before iOS kills it for memory. On iOS this ceiling sits well
    /// below physical RAM (a 6 GB device often gives a process only ~3 GB even
    /// with the increased-memory entitlement), so it's the real OOM limit.
    /// Reports 0 when unavailable (e.g. some simulator conditions).
    static var processAvailableMemory: Int64 {
        Int64(os_proc_available_memory())
    }

    /// Device RAM not resident in THIS process (deviceTotalRAM − our own
    /// `resident_size`), in bytes. NOT "free physical memory" — other apps'
    /// and the OS's pages still count as available here. Useful only to
    /// recover an approximate resident size (`deviceTotalRAM − this`), e.g.
    /// the `processMemoryCeiling` fallback and the diagnostics snapshots.
    /// Reports 0 on failure.
    static var nonResidentRAMEstimate: Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let used = Int64(info.resident_size)
            return max(0, deviceTotalRAM - used)
        }
        return 0
    }

    /// This process's current `phys_footprint` in bytes — the SAME accounting
    /// the kernel uses to decide `os_proc_available_memory()` and to Jetsam the
    /// app. Reports 0 on failure.
    ///
    /// This is deliberately NOT `mach_task_basic_info.resident_size`. The two
    /// diverge for GPU / IOKit allocations: an MLX/Metal model's weight buffers
    /// count toward `phys_footprint` (and therefore against the memory limit)
    /// but are largely absent from `resident_size`. Mixing the two — as the old
    /// `processMemoryCeiling` did (`os_proc_available_memory() + resident_size`)
    /// — made the ceiling read ~1 GB+ LOW whenever a VLM was resident, because
    /// `os_proc_available_memory()` had already subtracted the GPU footprint
    /// while `resident_size` never added it back. That's the "open the Lens
    /// VLM, switch to Assistant, Qwen3-4B is suddenly too large for this
    /// device" bug: the ceiling was polluted by the just-used VLM's GPU memory.
    static var physFootprint: Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    // MARK: - Entitlement-aware ceiling
    //
    // CodeLens ships the `increased-memory-limit` entitlement. On some devices
    // `os_proc_available_memory()` under-reports, so we fuse that signal with
    // an empirical per-tier fraction of physical RAM. The result still needs a
    // platform cap: build 45 proved that a 12 GB iPhone can report ~9.2 GB of
    // apparent headroom and then be Jetsam-killed around a 5.6 GB footprint.
    // iPad and Mac keep the scalable estimate; iPhone uses the validated bound.

    /// Fraction of physical RAM the app can realistically use as a hard ceiling
    /// on this device class. Tuned empirically against the entitled per-process
    /// limit (it sits well below 100% of device RAM even with the entitlement).
    /// These fractions provide the synthetic candidate. `clampedProcessCeiling`
    /// applies the separately validated iPhone ceiling afterward.
    private static var entitlementCeilingFraction: Double {
        switch DeviceTierAdvisor.current {
        case .lite, .entry: return 0.55   // ≤4 GB — keep very tight
        case .mid:          return 0.62   // 6 GB
        case .pro:          return 0.72   // 8 GB  → ~6.2 GB usable
        case .max:          return 0.76   // 12 GB+ (12 GiB) → ~9.8 GB usable
        }
    }

    /// Hard reserve always kept for the OS + other apps, regardless of tier.
    private static let physicalOSReserve: Int64 = 1_500_000_000

    /// Conservative process cap for iPhones below the 12 GB Max tier.
    static let maximumIPhoneProcessCeiling: Int64 = 6_200_000_000

    /// 12 GB Pro Max devices have a materially larger entitled process budget.
    /// Keep ~3.7 GB outside CodeLens while allowing a 5–6 GB quantized model
    /// plus its measured load envelope. The previous universal 6.2 GB clamp
    /// was introduced while stale MLX loads could overlap; after serializing
    /// model loads it unnecessarily rejects Ornith 9B on this tier.
    static let maximumHighMemoryIPhoneProcessCeiling: Int64 = 8_500_000_000
    static let highMemoryIPhoneRAMThreshold: Int64 = 10_000_000_000

    private static var isIPhoneProcess: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// Applies physical and platform bounds to a candidate process ceiling.
    /// Kept injectable so the real-device Jetsam regression is unit-testable
    /// without depending on the test host's RAM or interface idiom.
    static nonisolated func clampedProcessCeiling(
        candidate: Int64,
        totalRAM: Int64,
        isPhone: Bool
    ) -> Int64 {
        let physicalCap = max(0, totalRAM - physicalOSReserve)
        let phoneCap = totalRAM >= highMemoryIPhoneRAMThreshold
            ? maximumHighMemoryIPhoneProcessCeiling
            : maximumIPhoneProcessCeiling
        let platformCap = isPhone ? min(physicalCap, phoneCap) : physicalCap
        return min(max(0, candidate), platformCap)
    }

    /// Best estimate of this process's hard memory ceiling (the per-process
    /// limit iOS enforces), in bytes — independent of what is loaded right now.
    ///
    /// Fuses two signals and trusts the larger:
    ///   • Kernel: `os_proc_available_memory()` + current `phys_footprint`.
    ///     Both use the identical footprint accounting, so the sum recovers the
    ///     limit and is STABLE regardless of what is resident. (The previous
    ///     version added `resident_size`, which omits GPU/Metal buffers, so the
    ///     ceiling sagged by a resident VLM's GPU footprint — the "open Lens,
    ///     switch to Assistant, 4B won't load" regression. See `physFootprint`.)
    ///   • Entitlement: `physicalRAM × tierFraction`. Recovers the headroom the
    ///     kernel signal hides on entitled devices.
    /// Clamped to `physicalRAM − 1.5 GB`; iPhone is additionally capped at
    /// the empirically validated 6.2 GB process budget.
    static var processMemoryCeiling: Int64 {
        let avail = processAvailableMemory
        let footprint = physFootprint
        let kernelCeiling: Int64 = (avail > 0 && footprint > 0)
            ? avail + footprint
            : (avail > 0 ? avail + max(0, deviceTotalRAM - nonResidentRAMEstimate) : 0)
        let entitlementCeiling = Int64(Double(deviceTotalRAM) * entitlementCeilingFraction)
        let best = max(kernelCeiling, entitlementCeiling)
        let fallback = best > 0 ? best : availableRAM
        return clampedProcessCeiling(
            candidate: fallback,
            totalRAM: deviceTotalRAM,
            isPhone: isIPhoneProcess
        )
    }

    /// Live memory the app can realistically still allocate RIGHT NOW, in bytes
    /// — the figure the load gate compares a model's footprint against. Like
    /// `processMemoryCeiling` it fuses the kernel headroom with the
    /// entitlement-fraction estimate. The final headroom is always derived
    /// from `processMemoryCeiling`, so neither optimistic signal can exceed the
    /// validated platform budget.
    static var availableMemoryForModel: Int64 {
        let footprint = physFootprint
        return max(0, processMemoryCeiling - footprint)
    }

    // MARK: - Device fit (for suggestion badges)

    enum Fit {
        case fits        // comfortably within the ceiling, with reserve to spare
        case tight       // fits, but with little headroom — may throttle / fail under pressure
        case over        // exceeds the ceiling — won't load on this device

        var label: String {
            switch self {
            case .fits:  return "fits"
            case .tight: return "tight"
            case .over:  return "too big"
            }
        }
    }

    /// Classifies whether a model of the given peak footprint fits this device.
    ///
    /// Measured against live `processAvailableMemory`. On the Models tab the app
    /// has unloaded every model (ContentView does this on entering the tab), so
    /// that figure is the true headroom a fresh load can use — the honest answer
    /// to "will this run without an OOM crash." `.fits` keeps the full reserve;
    /// `.tight` would load only with the reserve dropped (edge mode); `.over`
    /// cannot load at all.
    static func fit(forFootprint footprint: Int64) -> Fit {
        guard footprint > 0 else { return .fits }
        let avail = availableMemoryForModel > 0 ? availableMemoryForModel : availableRAM
        if footprint + loadHeadroomReserve <= avail { return .fits }
        if footprint <= avail { return .tight }
        return .over
    }

    /// Convenience: fit verdict for a model id, using its estimated peak.
    static func fit(forModelID modelID: String) -> Fit {
        let footprint = estimatedFootprint(for: modelID)
        return fit(forFootprint: footprint > 0 ? footprint : unknownFootprintFloor)
    }

    // MARK: - Model footprints (working-set estimates)

    /// Best-effort working-set estimate per model, in bytes.
    /// Falls back to AssistantModelCatalog preset metadata and finally to an
    /// on-disk-size × 1.6 estimate so downloaded / imported models are no
    /// longer reported as "0 — fits anywhere".
    static func estimatedFootprint(for modelID: String) -> Int64 {
        // 1. Built-ins with hand-tuned numbers
        switch modelID {
        case "qwen3-1.7b":       return 1_500_000_000   // ~1.5 GB peak
        case "qwen3-4b":         return 3_800_000_000   // ~3.8 GB peak
        case "qwen3-8b":         return 6_500_000_000   // ~6.5 GB peak
        case FastVLMService.modelID: return 1_400_000_000   // ~1.4 GB peak
        case "kittentts-nano":   return 250_000_000     // ~250 MB
        case "kittentts-mini":   return 700_000_000     // ~700 MB
        case "kokoro":           return 400_000_000     // ~400 MB
        default: break
        }
        // 2. Preset bytes from the assistant catalog
        if let preset = AssistantModelCatalog.model(forID: modelID) {
            return preset.approxRAMBytes
        }
        // 3. Custom/downloaded/imported — parse the prefix and look up the
        //    on-disk repo size. Peak working set ≈ weights × workingSetOverhead
        //    (KV cache + activations). This is the *final* peak estimate; the
        //    gate does not multiply it again.
        if let repoID = nonPresetRepoID(from: modelID),
           let onDisk = onDiskWeightsSize(forRepoID: repoID), onDisk > 0 {
            return Int64(Double(onDisk) * workingSetOverhead)
        }
        return 0
    }

    /// Pulls the bare repoID out of `downloaded:…`, `imported:…`, `custom:…`.
    private static func nonPresetRepoID(from modelID: String) -> String? {
        let unwrapped = LocalModelRegistry.unwrapAssistantSelectionID(modelID)
        return unwrapped == modelID ? nil : unwrapped
    }

    // On-disk size cache. `allocatedSizeOfDirectory` recursively sums every
    // file in a multi-GB model folder — far too expensive to run per row on
    // every scroll frame, which is exactly what `estimatedFootprint` did once
    // it started driving the Models-tab fit badges. The result is stable while
    // browsing (a folder doesn't change size unless a download completes), so
    // we memoize it. `-1` is the "checked, nothing on disk" sentinel so a
    // not-yet-downloaded repo isn't re-walked every frame either.
    private static let _diskSizeLock = NSLock()
    nonisolated(unsafe) private static var _diskSizeCache: [String: Int64] = [:]

    /// Drops the on-disk size cache. Call when the installed set changes (a
    /// download finishes, a model is deleted) so freshly-sized repos are
    /// re-measured on next access. Cheap; safe to call liberally.
    static func invalidateFootprintCache() {
        _diskSizeLock.lock()
        _diskSizeCache.removeAll(keepingCapacity: true)
        _diskSizeLock.unlock()
    }

    /// On-disk allocated size of the repo's local copy, in bytes. Memoized —
    /// see `_diskSizeCache`. Returns nil if the directory doesn't exist.
    private static func onDiskWeightsSize(forRepoID repoID: String) -> Int64? {
        _diskSizeLock.lock()
        if let cached = _diskSizeCache[repoID] {
            _diskSizeLock.unlock()
            return cached < 0 ? nil : cached
        }
        _diskSizeLock.unlock()

        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = repoID.replacingOccurrences(of: "/", with: "_")
        let dest = docs.appendingPathComponent("HFModels", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
        let result: Int64? = FileManager.default.fileExists(atPath: dest.path)
            ? (try? FileManager.default.allocatedSizeOfDirectory(at: dest))
            : nil

        _diskSizeLock.lock()
        _diskSizeCache[repoID] = result ?? -1
        _diskSizeLock.unlock()
        return result
    }

    // MARK: - Verdicts

    enum Verdict {
        case fitsComfortably         // < 60% of available
        case marginal(String)        // 60–90% of available; warn but allow
        case wontFit(String)         // > 90% — block

        var color: String {
            switch self {
            case .fitsComfortably: return "green"
            case .marginal:        return "orange"
            case .wontFit:         return "red"
            }
        }

        var isBlocking: Bool {
            if case .wontFit = self { return true }
            return false
        }
    }

    /// Returns a verdict for loading `modelID` in addition to whatever is
    /// already considered loaded (sum the estimates).
    static func verdict(for modelID: String, alreadyLoaded: [String] = []) -> Verdict {
        let footprint = estimatedFootprint(for: modelID)
        let loadedFootprints = alreadyLoaded.map { estimatedFootprint(for: $0) }
        return verdict(forFootprint: footprint, alreadyLoadedFootprints: loadedFootprints)
    }

    /// Verdict for callers that already have a hand-tuned peak footprint (image
    /// generation / curated VLM catalog). Keeps picker badges aligned with the
    /// same live-memory requirement enforced by the load gates.
    static func verdict(
        forFootprint footprint: Int64,
        alreadyLoadedFootprints: [Int64] = []
    ) -> Verdict {
        guard footprint > 0 else { return .fitsComfortably }

        let combined = footprint + alreadyLoadedFootprints.reduce(0, +)
        let procAvail = availableMemoryForModel
        let budget = procAvail > 0 ? procAvail : availableRAM
        let reserve = AppSettings.shared.showEdgeModels ? edgeHeadroomReserve : loadHeadroomReserve
        let needed = combined + reserve

        if needed > budget {
            return .wontFit(String(
                format: "Needs ~%.1f GB but only ~%.1f GB is available to the app right now. Close other apps and retry.",
                Double(needed) / 1_000_000_000,
                Double(budget) / 1_000_000_000
            ))
        }
        if Double(needed) / Double(max(1, budget)) > 0.85 {
            return .marginal("This model fits, but uses most of the app's ~\(budget.formattedBytes) current memory headroom. Close other apps if loading is interrupted.")
        }
        return .fitsComfortably
    }

    /// Verdict considering models currently flagged as loaded.
    /// Must be called from MainActor since it reads service singletons.
    @MainActor
    static func verdictWithCurrentlyLoaded(for modelID: String) -> Verdict {
        let footprint = estimatedFootprint(for: modelID)
        return verdictWithCurrentlyLoaded(forFootprint: footprint, excludingModelID: modelID)
    }

    /// Same as `verdictWithCurrentlyLoaded(for:)`, but for callers with a
    /// curated footprint that is not keyed in `estimatedFootprint`.
    @MainActor
    static func verdictWithCurrentlyLoaded(
        forFootprint footprint: Int64,
        excludingModelID modelID: String? = nil
    ) -> Verdict {
        var loaded: [String] = []
        if CodingAssistantService.shared.state == .ready {
            // Whatever the assistant currently holds, not a hardcoded ID.
            loaded.append(CodingAssistantService.shared.activeModel.id)
        }
        if FastVLMService.shared.componentStatus.canGenerate { loaded.append(FastVLMService.modelID) }
        let others = loaded.filter { loadedID in
            guard let modelID else { return true }
            return loadedID != modelID
        }
        return verdict(
            forFootprint: footprint,
            alreadyLoadedFootprints: others.map { estimatedFootprint(for: $0) }
        )
    }

    // MARK: - Combined device-safety verdict

    /// Combined verdict: RAM + live free memory + thermal state + low-power.
    /// Use this before kicking off a model load. Returns nil when it's safe.
    ///
    /// Thermal handling here follows Apple's actual guidance: only block
    /// at `.critical`. The previous threshold (block >1.5 GB models at
    /// `.serious`) refused Qwen3-4B (~2.3 GB) the moment the device got
    /// even moderately warm, which on an A19 Pro is the working state
    /// during sustained inference. iOS's own thermal scheduler already
    /// throttles CPU/GPU clocks at `.serious`; we don't need to layer a
    /// hard refuse on top.
    @MainActor
    static func safetyBlocker(
        for modelID: String,
        allowTightFit: Bool = false,
        runtime: ModelRuntime? = nil,
        allowUnsafeMemoryLoad: Bool = false
    ) -> String? {
        // Callers that can start MLX work must await
        // `MLXGenerationGate.clearCacheWhenIdle()` before entering this
        // synchronous measurement. A state-based "nothing is generating"
        // check is racy: a native load or a just-cancelled Metal command can
        // still be live after the published UI state changes.

        // 1. Thermal: only refuse at .critical. .serious is workable on
        //    modern silicon and iOS already does its own backoff there.
        if DeviceSafetyMonitor.shared.thermalState == .critical {
            return "Device is too hot to safely load this model. Let it cool for a minute, then retry."
        }

        // A user-confirmed experimental attempt bypasses memory-capacity
        // admission for this call only. Critical thermal protection remains:
        // adding a known-oversized allocation while iOS is already throttling
        // at its highest level is not a useful model test.
        if allowUnsafeMemoryLoad {
            return nil
        }

        // 1b. Post-pressure cooldown. iOS recently hit CRITICAL memory pressure
        //     and we dumped weights; refuse heavy reloads briefly so we don't
        //     race the kernel's reclaim into a Jetsam kill. A small model that
        //     comfortably fits the live headroom is still allowed to recover.
        if let remaining = pressureCooldownRemaining {
            let footprint = estimatedFootprint(for: modelID)
            let assumed = footprint > 0 ? footprint : unknownFootprintFloor
            // A model may load during the cooldown if it COMFORTABLY fits the
            // live headroom right now, full reserve kept. The earlier gate also
            // required `assumed <= smallRecoveryModelCeiling` (1 GB) — but every
            // shipping model is ≥1.4 GB, so NO real model could ever recover and
            // the assistant/lens was dead for the whole 20s window even after
            // the dump had freed plenty of memory. The full reserve is the
            // safety margin against the in-flight reclaim race; the size ceiling
            // added nothing but the dead-end.
            let fitsAsRecovery = assumed + loadHeadroomReserve <= availableMemoryForModel
            if !fitsAsRecovery {
                let secs = max(1, Int(remaining.rounded(.up)))
                return "iOS just reported a memory-pressure spike. Wait ~\(secs)s for it to recover memory, then retry."
            }
        }

        // 2. RAM verdict (physical-memory heuristic). Adjustable: when the
        //    user relaxes the strict gate, skip this conservative check but
        //    still enforce the hard per-process ceiling below — that one
        //    reflects memory the kernel will actually grant, so ignoring it
        //    means a near-certain crash.
        if AppSettings.shared.strictMemoryGate {
            if case .wontFit(let msg) = verdictWithCurrentlyLoaded(for: modelID) {
                let footprint = estimatedFootprint(for: modelID)
                let fitsWithoutReserve = footprint > 0
                    && footprint <= availableMemoryForModel
                if !allowTightFit || !fitsWithoutReserve {
                    return msg
                }
            }
        }

        // 3. Live per-process ceiling — the real OOM killer on iOS. The verdict
        //    above reasons about *physical* RAM (70% of device total), but iOS
        //    caps each process well below that. A model can pass the physical
        //    heuristic (e.g. 3.8 GB on a "4.2 GB usable" 6 GB device) yet still
        //    exceed the ~3 GB the kernel will actually hand this process — that
        //    mismatch is the classic "passes the gate, crashes on load" case.
        //    This backstop refuses outright before the allocation that would
        //    SIGKILL the app. When the static footprint is unknown (custom /
        //    imported models that don't match a preset or an on-disk folder),
        //    fall back to a conservative floor so an unsized large model can't
        //    slip through with needed == 0.
        // Use the entitlement-aware live figure, NOT raw
        // os_proc_available_memory(): on entitled devices the latter
        // under-reports and refuses models that comfortably fit (the core
        // "device has RAM but the model won't load" report).
        let procAvail = availableMemoryForModel
        if procAvail > 0 {
            let footprint = estimatedFootprint(for: modelID)
            let assumed = footprint > 0 ? footprint : unknownFootprintFloor
            // `assumed` is already the peak resident working set (it includes
            // the load transient — see `estimatedFootprint`). Add only a fixed
            // reserve for app/runtime/OS glue. Multiplying the peak again here
            // is what previously inflated every estimate ~2.5× and refused
            // models that comfortably fit the per-process ceiling.
            //
            // Edge / developer mode drops the reserve so a "tight" model that
            // sits right at the ceiling can load — experimental, may be killed
            // under pressure. A normal user keeps the full reserve, so they
            // never load anything that would OOM. Either way a model whose peak
            // genuinely exceeds the live ceiling is still refused.
            let reserve = (AppSettings.shared.showEdgeModels || allowTightFit)
                ? edgeHeadroomReserve
                : loadHeadroomReserve
            let needed = assumed + reserve
            if procAvail < needed {
                // Distinguish "too big for this device, period" from "would
                // fit if you freed up what's resident right now." The hard
                // ceiling (`processMemoryCeiling`) is what this process can
                // ever allocate with nothing else loaded; if `needed` exceeds
                // even that, telling the user to "unload other models" is
                // wrong — no amount of freeing helps, they need a smaller
                // model. This is the common "Qwen2.5 7B won't load" case on
                // 6 GB devices whose per-process ceiling sits below ~5 GB.
                let ceiling = processMemoryCeiling
                if needed > ceiling {
                    return hardCeilingMessage(
                        neededBytes: needed,
                        ceilingBytes: ceiling,
                        runtime: runtime,
                        lowMemoryEnabled: allowTightFit
                    )
                }
                return String(
                    format: "Not enough memory to load this model safely (~%.1f GB needed, only ~%.1f GB available to the app). Unload other models or close some apps, then retry.",
                    Double(needed) / 1_000_000_000,
                    Double(procAvail) / 1_000_000_000
                )
            }
        }
        return nil
    }

    /// Explains a hard process-ceiling refusal without implying that the
    /// low-memory switch can page every model format. MLX can reduce retained
    /// allocator/KV cache, but its full weights still count against the iOS
    /// process limit. Only llama.cpp's GGUF path can keep weights file-backed
    /// and let iOS reclaim clean pages.
    static nonisolated func hardCeilingMessage(
        neededBytes: Int64,
        ceilingBytes: Int64,
        runtime: ModelRuntime?,
        lowMemoryEnabled: Bool
    ) -> String {
        let neededGB = Double(neededBytes) / 1_000_000_000
        let ceilingGB = Double(ceilingBytes) / 1_000_000_000
        if runtime == .mlx, lowMemoryEnabled {
            return String(
                format: "This MLX model needs ~%.1f GB, but this app can use ~%.1f GB on this device. Low-memory mode cannot page MLX weights. Choose a smaller MLX model (4B or 1.7B), or import a GGUF quantization for storage-backed paging.",
                neededGB,
                ceilingGB
            )
        }
        return String(
            format: "This model is too large for this device (~%.1f GB needed, but the app can use at most ~%.1f GB here). Pick a smaller model — a 4B or 1.7B fits comfortably.",
            neededGB,
            ceilingGB
        )
    }

    /// Capacity failures cannot be fixed by retrying the same model. Keep the
    /// classification beside the messages it recognizes so recovery UI does
    /// not depend on a particular model name or byte estimate.
    static nonisolated func isHardCapacityFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("this mlx model needs")
            || normalized.contains("model is too large for this device")
    }

    // MARK: - Device summary

    static var deviceSummary: String {
        "\(deviceTotalRAM.formattedBytes) total · ~\(availableRAM.formattedBytes) usable for ML"
    }
}
