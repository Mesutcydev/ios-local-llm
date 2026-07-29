import Foundation

// MARK: - VisualModelInstallStatus
//
// Unified "is this VLM actually runnable right now" check. Picker rows and
// the apply() gate use this so any VLM the user can pick will load through
// the correct backend without crashing.
//
// Each VLM in `ModelDownloadCenter` is one of three backends:
//   • FastVLM        — Core ML encoder mlpackage + MLX decoder safetensors
//   • GGUF (mtmd)    — paired `<model>.gguf` + `mmproj-<model>.gguf`
//   • MLX            — `config.json` + at least one `.safetensors` weight
//
// `DownloadableModel.isReady` only reflects what each model's HF downloader
// fetched (and uses a single-file heuristic for entries without an
// allowlist). It's not enough on its own:
//   • FastVLM: the encoder mlpackage is a sibling path, not inside the
//     decoder's download destination, so `isReady` ignores it.
//   • GGUF: a half-downloaded pair (LLM-only, missing mmproj) shouldn't
//     count as runnable.
//
// This module narrows the truth.

enum VisualModelBackend {
    case fastVLM
    case gguf
    case mlx
}

/// Runnability state for a single VLM catalog entry.
enum VisualModelRunStatus: Equatable {
    case ready
    case partial(String)        // downloaded something, but not enough to run
    case notInstalled

    var isReady: Bool { self == .ready }

    var shortLabel: String {
        switch self {
        case .ready:        return "installed"
        case .partial:      return "incomplete"
        case .notInstalled: return "not installed"
        }
    }

    var actionMessage: String {
        switch self {
        case .ready:
            return ""
        case .partial(let why):
            return why
        case .notInstalled:
            return "Download this model in the Model Center to enable it."
        }
    }
}

@MainActor
enum VisualModelInstallStatus {

    // MARK: - Backend detection

    /// Picks the right backend for a `DownloadableModel`. Prefer the catalog's
    /// explicit runtime contract so imported/future GGUF VLMs do not need a
    /// particular substring in their display or repository name. The filename
    /// heuristic remains only as a compatibility fallback for older entries.
    static func backend(for model: DownloadableModel) -> VisualModelBackend {
        if model.id == FastVLMService.modelID { return .fastVLM }
        if model.runtime == .llamaCpp { return .gguf }
        if model.runtime == .mlx { return .mlx }
        if model.id.lowercased().contains("gguf") { return .gguf }
        return .mlx
    }

    /// Short human-readable format label for a row badge.
    /// "Core ML + MLX" for FastVLM, "GGUF" for mtmd VLMs, "MLX" otherwise.
    static func formatLabel(for model: DownloadableModel) -> String {
        switch backend(for: model) {
        case .fastVLM: return "Core ML + MLX"
        case .gguf:    return "GGUF"
        case .mlx:     return "MLX"
        }
    }

    // MARK: - Runnability

    /// Returns the strict runnability state — what each backend actually
    /// requires on disk, not just whether the downloader is happy.
    static func runStatus(for model: DownloadableModel) -> VisualModelRunStatus {
        switch backend(for: model) {
        case .fastVLM:
            return mapFastVLM(FastVLMService.installStatus())
        case .gguf:
            return ggufRunStatus(for: model)
        case .mlx:
            return mlxRunStatus(for: model)
        }
    }

    private static func mapFastVLM(_ status: FastVLMService.InstallStatus) -> VisualModelRunStatus {
        switch status {
        case .ready:          return .ready
        case .encoderMissing: return .partial(status.actionMessage)
        case .decoderMissing: return .partial(status.actionMessage)
        case .notInstalled:   return .notInstalled
        }
    }

    private static func ggufRunStatus(for model: DownloadableModel) -> VisualModelRunStatus {
        if LlamaCppVLMService.stagedDirectory(for: model.sourceRepoID) != nil {
            return .ready
        }
        // If the downloader fetched something but no GGUF pair landed on
        // disk, surface that as partial — the typical case is one of the
        // pair files failed to resume.
        if model.isReady {
            return .partial("GGUF pair incomplete — need both <model>.gguf and mmproj-<model>.gguf.")
        }
        return .notInstalled
    }

    private static func mlxRunStatus(for model: DownloadableModel) -> VisualModelRunStatus {
        // The HF downloader's own readiness check is our source of truth
        // for MLX models — it already verifies allowlist files (or
        // `config.json` when no allowlist) under the destination.
        model.isReady ? .ready : .notInstalled
    }

    // MARK: - Memory verdict

    /// Key passed to MemoryAdvisor. FastVLM uses its hardcoded
    /// `fastvlm-mlx` ID (matches the hand-tuned footprint table); every
    /// other VLM uses the `downloaded:<repoID>` prefix so MemoryAdvisor
    /// falls through to `onDiskWeightsSize(forRepoID:)` and reports a
    /// real estimate instead of 0 (= "fits anywhere").
    private static func memoryKey(for model: DownloadableModel) -> String {
        LocalModelRegistry.visionMemoryAdvisorKey(for: model.sourceRepoID)
    }

    /// Best-effort RAM working-set estimate in bytes. 0 when nothing on
    /// disk (download still pending). Callers can format with
    /// `Int64.formattedBytes`.
    static func ramEstimate(for model: DownloadableModel) -> Int64 {
        if let ram = model.approxRAMBytes, ram > 0 { return ram }
        switch backend(for: model) {
        case .fastVLM:
            return MemoryAdvisor.estimatedFootprint(for: FastVLMService.modelID)
        case .gguf:
            let weights = LlamaCppVLMService.estimatedWeightBytes(repoID: model.sourceRepoID)
            return Int64(Double(weights) * MemoryAdvisor.loadSpikeMultiplier)
        case .mlx:
            let weights = LensInferenceLoop.estimatedWeightBytes(repoID: model.sourceRepoID)
            return Int64(Double(weights) * MemoryAdvisor.loadSpikeMultiplier)
        }
    }

    /// Best-effort RAM verdict for adding this VLM to whatever's already
    /// loaded. Live-RAM check via `verdictWithCurrentlyLoaded` so a
    /// device under pressure downgrades from green to amber/red.
    static func memoryVerdict(for model: DownloadableModel) -> MemoryAdvisor.Verdict {
        let footprint = ramEstimate(for: model)
        if footprint > 0 {
            return MemoryAdvisor.verdictWithCurrentlyLoaded(
                forFootprint: footprint,
                excludingModelID: memoryKey(for: model)
            )
        }
        return MemoryAdvisor.verdictWithCurrentlyLoaded(for: memoryKey(for: model))
    }

    // MARK: - Perf history

    /// Average tokens/sec across recent runs of this model, or nil if the
    /// user hasn't generated with it yet. Picker shows "—" in that case.
    static func avgTokensPerSecond(for model: DownloadableModel) -> Double? {
        let id = model.id
        guard let avg = ModelUsageTracker.shared.avgTPS(for: id), avg > 0 else {
            return nil
        }
        return avg
    }

    /// Compact perf label: "23 tok/s · 2m ago" / "23 tok/s" / "—".
    static func perfLabel(for model: DownloadableModel) -> String {
        guard let tps = avgTokensPerSecond(for: model) else { return "—" }
        let tpsStr = String(format: "%.0f tok/s", tps)
        if let last = ModelUsageTracker.shared.lastUsed(for: model.id) {
            return "\(tpsStr) · \(last.relativeShort)"
        }
        return tpsStr
    }
}
