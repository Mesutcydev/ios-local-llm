import Foundation

// MARK: - DeviceTierAdvisor
// Classifies the current device and recommends a sensible default LLM that
// will run smoothly without OOM-ing. Used on first launch so the user doesn't
// have to navigate the picker before getting a working chat — and so cheap
// devices don't try to load a 4B model and crash on cold start.
//
// The thresholds are based on iOS device RAM:
//   • 3 GB  → iPhone XR / SE 2-3 (lite tier)
//   • 4 GB  → iPhone 11 / 12 / mini (entry tier)
//   • 6 GB  → iPhone 13 / 14 / 15 standard (mid tier)
//   • 8 GB  → iPhone 15 Pro / 16 / 17 (pro tier)
//   • ≥12 GB → iPhone 16 Pro Max / future (max tier)

enum DeviceTier: String, CaseIterable {
    case lite      // < 4 GB
    case entry     // 4 GB
    case mid       // 6 GB
    case pro       // 8 GB
    case max       // 12+ GB

    var label: String {
        switch self {
        case .lite:  return "lite"
        case .entry: return "entry"
        case .mid:   return "mid"
        case .pro:   return "pro"
        case .max:   return "max"
        }
    }
}

enum DeviceTierAdvisor {

    /// Current device's tier, determined from physical RAM.
    static var current: DeviceTier {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        switch gb {
        case ..<3.5:  return .lite
        case ..<5.0:  return .entry
        case ..<7.0:  return .mid
        case ..<10.0: return .pro
        default:      return .max
        }
    }

    /// Preset AssistantModel id appropriate for this device. Conservative on
    /// purpose — the user can always upgrade in the picker.
    static var recommendedModelID: String {
        switch current {
        case .lite, .entry: return "qwen2.5-coder-1.5b"  // 900 MB · safe everywhere
        case .mid:          return "llama-3.2-3b"        // 1.8 GB · sweet spot
        case .pro:          return "qwen3-4b-2507"       // 2.3 GB · refreshed flagship
        case .max:          return "qwen2.5-7b"          // 4.2 GB · best quality
        }
    }

    /// One-line human-readable rationale, shown to the user during onboarding.
    static var rationale: String {
        switch current {
        case .lite:
            return "Your device has limited RAM. Starting with our smallest, fastest model."
        case .entry:
            return "Picked a coder-tuned 1.5B model — fast and reliable on this device."
        case .mid:
            return "Llama 3.2 3B fits comfortably here and gives richer answers."
        case .pro:
            return "Qwen3-4B 2507 — refreshed flagship, high quality and runs well here."
        case .max:
            return "Qwen2.5 7B — top quality. Plenty of RAM headroom on this device."
        }
    }

    /// Tier-appropriate response length cap (max tokens). Conservative on
    /// low-RAM devices so the KV cache doesn't stress limited GPU memory.
    static var recommendedMaxTokens: Int {
        switch current {
        case .lite:  return 512    // XR / SE — short replies to stay safe
        case .entry: return 768    // iPhone 11/12 — normal length
        case .mid:   return 1024   // iPhone 13/14/15 — comfortable
        case .pro:   return 2048   // Pro devices — enough room for Qwen reasoning
        case .max:   return 3072   // Max devices — long replies without crowding KV
        }
    }

    // MARK: - Feature gating
    //
    // After `DeviceCompatibility.isSupported()` cleared the install,
    // every device in the field is ≥8 GB RAM — i.e. .pro or .max
    // tier. Some features still don't fit cleanly in 8 GB: a 6.5 GB
    // Qwen3-8B working set leaves no room for the OS, camera, KV
    // cache, or Metal heap on a .pro device. Surfacing them in the
    // picker is worse than hiding them — users tap, hit OOM, and
    // blame the app.
    //
    // `shouldHideHeavyFeatures` is the single flag callers consult.
    // True on .pro / .lite / .entry / .mid (anything not .max). The
    // pre-gate tiers are unreachable in production but the test
    // harness can still simulate them.

    /// True when the current device should be steered away from
    /// memory-heavy models / multi-model UIs. False only on .max.
    static var shouldHideHeavyFeatures: Bool {
        current != .max
    }

    /// Approximate RAM ceiling in bytes for a SINGLE model on this
    /// device. Conservative — leaves room for the OS, the camera
    /// pipeline (~150 MB), Metal heap (~400 MB), and one resident
    /// VLM (~520 MB bundled GGUF). Models with `approxRAMBytes`
    /// above this should not appear in the picker.
    static var singleModelRAMBudget: UInt64 {
        switch current {
        case .lite:  return 1_000_000_000   // 1.0 GB
        case .entry: return 1_500_000_000   // 1.5 GB
        case .mid:   return 2_500_000_000   // 2.5 GB
        case .pro:   return 4_500_000_000   // 4.5 GB — fits Qwen3-4B, blocks 7B/8B
        case .max:   return 8_000_000_000   // 8.0 GB — fits everything
        }
    }

    // MARK: - Camera VLM recommendation

    /// Best on-device VLM repo for the camera tab, by device tier.
    ///
    /// Tier-aware recommendation.
    ///
    /// **As of the llama.cpp + mtmd integration**, the recommendation
    /// is `ggml-org/SmolVLM2-500M-Video-Instruct-GGUF` for ALL tiers
    /// — at 520 MB combined (LLM + mmproj) it fits comfortably even
    /// on the smallest devices, and llama.cpp's mtmd integration
    /// works where MLX's Idefics3 path is broken upstream. Users on
    /// .max can still pick larger Qwen3-VL variants from the
    /// Catalog if they want maximum quality at higher memory cost.
    ///
    /// CRITICAL: these targets are sized against the iOS per-process
    /// memory limit, not just device RAM. `MemoryAdvisor` uses the live
    /// kernel headroom when loading; this table stays conservative so the
    /// default never depends on a best-case foreground memory moment.
    ///
    ///   • `.max`  (12 GB+ device, live high-memory process budget) →
    ///     `mlx-community/Qwen3-VL-4B-Instruct-4bit` (~2.9 GB).
    ///     Peak load ≈ 4.6 GB → fits with ~1.4 GB headroom for KV
    ///     cache + app overhead. Qwen3-VL-8B (~5.4 GB) was the
    ///     previous default and was crashing this tier on load.
    ///
    ///   • `.pro`  (8 GB device, ~4–5 GB process limit) →
    ///     `mlx-community/Qwen3-VL-2B-Instruct-4bit` (~1.7 GB).
    ///     The previous 4B default was borderline-fits and risky
    ///     when the chat LLM was also resident. 2B is the safe
    ///     baseline.
    ///
    ///   • `.mid` / `.entry` / `.lite` (≤6 GB device, ~3 GB process
    ///     limit) → `Qwen3-VL-2B-Instruct-4bit`. Same as `.pro` —
    ///     2B is the smallest Qwen-VL we can rely on.
    ///
    /// SmolVLM / Idefics3-family models have been removed entirely.
    /// They have a known upstream Index-out-of-range crash in
    /// mlx-swift-examples' `prepareInputsForMultimodal`. See
    /// LENS_PIPELINE.md and `VLMCapabilities.isLensPipelineCompatible`
    /// for the runtime guard.
    static var recommendedVisualModelRepoID: String {
        // SmolVLM2-500M-Video-Instruct Q8 GGUF is the new default
        // for every tier: 520 MB, fast, runs through llama.cpp +
        // mtmd (LlamaCppVLMService) which doesn't share the MLX
        // SmolVLM bug. Users on .max who want maximum quality can
        // pick Qwen3-VL-4B from the Catalog.
        return "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"
    }

    /// Fallback chain when the primary repo fails to load.
    /// MLXVisionService walks these in order. Per-tier so the chain
    /// stays sized for the device's process limit.
    ///
    /// Qwen3-VL-8B intentionally NOT in any default chain — at 5.4 GB on
    /// disk its load peak is too close to the iPhone process budget on many
    /// devices. Power users can still pick it manually; the live memory gate
    /// will allow it only on hardware/OS combinations that report enough
    /// headroom, otherwise refusing with a clear error instead of a crash.
    ///
    /// **Gemma 3 4B IT** is offered in the catalog as the bounded-context
    /// `ggml-org/gemma-3-4b-it-GGUF` pair. It runs through llama.cpp + mtmd,
    /// not this MLX fallback chain, so selecting it reaches the lower-peak
    /// backend directly while retaining Gemma's fixed 896² SigLIP encoder.
    static var visualModelFallbackRepoIDs: [String] {
        // SmolVLM2-GGUF first across all tiers (smallest, fastest,
        // works). Qwen3-VL variants follow as bigger / higher-
        // quality alternatives for users who downloaded them.
        switch current {
        case .max:
            return [
                "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
                "mlx-community/Qwen3-VL-4B-Instruct-4bit",
                "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            ]
        case .pro:
            return [
                "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
                "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            ]
        case .mid, .entry, .lite:
            return [
                "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
            ]
        }
    }

    /// Apply the recommendation if the user has never picked a model or
    /// response length themselves (first launch). Safe to call on every cold start.
    @MainActor
    static func applyDefaultIfNeeded() {
        let s = AppSettings.shared
        // `hasPickedAssistantModel` is the explicit "user touched the model
        // picker" flag. Without it we'd never auto-tune on devices where
        // assistantModelID was set by a stale default.
        if !s.hasPickedAssistantModel {
            s.assistantModelID = recommendedModelID
        }
        // Set a tier-appropriate token cap once per device unless the user
        // has already manually adjusted the response length setting.
        if !s.hasPickedResponseLength {
            s.assistantMaxTokens = recommendedMaxTokens
        }
    }

    /// HuggingFace repo IDs that earlier builds auto-selected but that
    /// turned out to 404 / lack required files. If a stale install still
    /// has one of these in `cameraVisualModelID`, we replace it with the
    /// current recommendation on next launch even though the user has
    /// "touched the picker" (auto-pick from a prior build counted as a
    /// touch, which trapped users on a broken repo).
    private static let staleVisualModelRepoIDs: Set<String> = [
        // Wrong organisation — SmolVLM2 lives under HuggingFaceTB, not mlx-community.
        "mlx-community/SmolVLM2-500M-Video-Instruct-mlx",
        "mlx-community/SmolVLM2-256M-Video-Instruct-mlx",
        "mlx-community/SmolVLM2-2.2B-Instruct-mlx",
        // Doesn't exist on the Hub — only the -4bit quantisation is published
        // for the original SmolVLM-Instruct under mlx-community.
        "mlx-community/SmolVLM-Instruct-bf16",
    ]

    /// Repo IDs that previously auto-defaulted from this app but produced
    /// systematically inaccurate captions, crashes, or have known upstream
    /// bugs. Users landing on one of these via the auto-default (NOT via
    /// an explicit pick) get migrated to the current recommendation.
    /// Distinguished from `staleVisualModelRepoIDs` because these repos DO
    /// exist and load — they just don't work for our use case. Migration
    /// respects `hasPickedCameraVisualModel`: if the user genuinely went
    /// to the picker and chose one of these, we don't override.
    private static let inaccurateAutoPickedVisualModelRepoIDs: Set<String> = [
        // SmolVLM2-500M-Video-Instruct (MLX): the old bundled default.
        // Removed entirely — bundled weights deleted from .app and
        // BundledVLMInstaller now ships the GGUF version instead.
        // ALSO had a known upstream crash in mlx-swift-examples.
        "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx",
        // SmolVLM-Instruct-4bit: previous image-only MLX default.
        // Same Idefics3 family, same upstream bug surface — migrate
        // anyone still on it to the GGUF path.
        "mlx-community/SmolVLM-Instruct-4bit",
    ]

    /// Repo IDs that we ACTIVELY migrate away from on next launch,
    /// regardless of whether the user "picked" them. Used for the
    /// case where the bundled assets they relied on no longer exist
    /// in the .app (e.g. the old MLX SmolVLM2 we just deleted) — the
    /// load would simply fail otherwise.
    static let forciblyMigrateAwayVisualModelRepoIDs: Set<String> = [
        // Old MLX SmolVLM2-Video bundle. The weights were deleted
        // from the app's Resources folder when we switched to the
        // GGUF Q8 pair. If a user upgrades and their persisted
        // cameraVisualModelID still points here, the load would
        // fail immediately. Force-migrate to the new recommendation
        // (SmolVLM2 GGUF, which IS bundled).
        "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx",
    ]

    /// First-launch wiring for the camera VLM. We default the user onto a
    /// tier-appropriate SmolVLM (the lens UI was clearly designed around
    /// SmolVLM-style captions) and trigger the background download so the
    /// camera works the first time they open it instead of staring at a
    /// "FastVLM failed to load" toast. Idempotent — switchTo() short-
    /// circuits when the chosen repo is already loaded, and HubApi
    /// short-circuits when the files are already cached on disk.
    @MainActor
    static func applyDefaultVisualModelIfNeeded() {
        let s = AppSettings.shared

        // One-shot migration: clear hasPickedCameraVisualModel if the
        // persisted repo id was auto-selected by an earlier build that
        // turned out to point at a broken repo. Without this, users who
        // launched with the old SmolVLM2 default get stuck on it forever
        // because the picker logic treats "set by anyone" as "user picked".
        if staleVisualModelRepoIDs.contains(s.cameraVisualModelID) {
            s.hasPickedCameraVisualModel = false
            s.cameraVisualModelID = ""
        }

        // Forced migration: bundled-asset removals require us to move
        // users off the now-invalid repoID, regardless of whether
        // they picked it manually. The most recent case is the
        // deletion of the MLX SmolVLM2-Video bundle when we switched
        // to the GGUF version — users persisted to that repoID would
        // fail to load on the new build because the weights are gone.
        if Self.forciblyMigrateAwayVisualModelRepoIDs.contains(s.cameraVisualModelID) {
            s.hasPickedCameraVisualModel = false
            s.cameraVisualModelID = ""
            print("[DeviceTierAdvisor] Forcibly migrated user off retired VLM repo")
        }

        // `inaccurateAutoPickedVisualModelRepoIDs` is the softer
        // version of the forced list — documented for future opt-in
        // migration UI but not actively re-routing today (users on
        // soft-deprecated repos still load, just suboptimally).
        _ = inaccurateAutoPickedVisualModelRepoIDs

        // Recovery: a previous build of this app migrated users from the
        // bundled SmolVLM2-Video-Instruct to mlx-community/SmolVLM-Instruct-4bit
        // (which isn't bundled, so the lens would silently wait for a
        // 600 MB download). If we detect that state — recommended repo
        // set, but its weights aren't on disk, AND the bundled repo IS
        // on disk — restore the bundled repo so the lens works
        // immediately. This is idempotent: once the new model is
        // downloaded, both branches have weights and the existing
        // selection wins.
        if !s.hasPickedCameraVisualModel,
           s.cameraVisualModelID == "mlx-community/SmolVLM-Instruct-4bit",
           !hasHubApiWeights(for: s.cameraVisualModelID),
           hasHubApiWeights(for: BundledVLMInstaller.bundledRepoID) {
            s.cameraVisualModelID = BundledVLMInstaller.bundledRepoID
        }

        guard !s.hasPickedCameraVisualModel else { return }

        // First-launch only: pick a tier-appropriate VLM so the picker
        // and the lens UI know which repo to target. We deliberately do
        // NOT call MLXVisionService.switchTo() here — that ran on every
        // cold launch in the previous shape and was the auto-load that
        // tripped `mlx::core::gpu::check_error` SIGABRTs before the user
        // even reached the lens tab. The actual model load now happens
        // lazily on first capture (AnalysisService.tryMLXVisionPath →
        // switchTo), which is gated by the user-initiated capture tap
        // in CameraRootView. Launch becomes free of any Metal work.
        //
        // Tier gate: only sub-8 GB devices auto-prefer the bundled
        // SmolVLM2. On .pro and .max we explicitly want to route to
        // Qwen3-VL (recommendedVisualModelRepoID) even though it
        // requires a one-time 3–5 GB download. The reason: SmolVLM2
        // has a known upstream Index-out-of-range crash in
        // mlx-swift-examples on non-square inputs (see LENS_PIPELINE.md
        // troubleshooting). The bundled-prefer optimisation is a
        // sub-8GB-only behavior now — those devices can't run Qwen3-VL
        // anyway, and they trade a broken-on-some-inputs experience
        // for a working-immediately one.
        let preferBundled: Bool
        switch current {
        case .lite, .entry, .mid: preferBundled = true
        case .pro, .max:          preferBundled = false
        }
        if preferBundled,
           (bundledVLMShipsWithApp() || hasHubApiWeights(for: BundledVLMInstaller.bundledRepoID))
        {
            s.cameraVisualModelID = BundledVLMInstaller.bundledRepoID
        } else {
            s.cameraVisualModelID = recommendedVisualModelRepoID
        }
    }

    /// True when the bundled SmolVLM2 weights are present in the .app
    /// (the resource-copy step ran at build time). This is the signal that
    /// BundledVLMInstaller will be able to populate the HubApi cache on
    /// first launch, so it's safe to commit to the bundled repo id even
    /// before the copy actually runs.
    private static func bundledVLMShipsWithApp() -> Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        let bundleFolderName = BundledVLMInstaller.bundledRepoID
            .replacingOccurrences(of: "/", with: "_")
        let root = resources
            .appendingPathComponent("SmolVLMWeights", isDirectory: true)
            .appendingPathComponent(bundleFolderName, isDirectory: true)
        // The safetensors is the only file large enough to be worth
        // checking — if it's there, the rest of the bundle is too.
        return FileManager.default
            .fileExists(atPath: root.appendingPathComponent("model.safetensors").path)
    }

    /// True when HubApi-shaped weights for `repoID` exist on disk at the
    /// canonical location. Used by the recovery branch above to decide
    /// whether falling back to the bundled VLM is safe (we only fall back
    /// when the bundled weights themselves are present).
    private static func hasHubApiWeights(for repoID: String) -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent(repoID)
        return ModelCacheProbe.isUsableModelDirectory(url)
    }
}
