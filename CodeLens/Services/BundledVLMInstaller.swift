import Foundation

// MARK: - BundledVLMInstaller
//
// First-launch priming for the bundled VLM. The current bundled
// model is `ggml-org/SmolVLM2-500M-Video-Instruct-GGUF` Q8_0 —
// a llama.cpp / mtmd model (NOT MLX). The previous bundled model
// (`HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx`, ~1 GB MLX
// safetensors) has been removed entirely because:
//
//   • mlx-swift-examples' SmolVLM2 integration is broken upstream
//     (Index out of range in `prepareInputsForMultimodal` — see
//     LENS_PIPELINE.md and Cesur2000/CodeLens#1)
//   • The GGUF version at Q8_0 is half the size (~520 MB total)
//     and works through llama.cpp + mtmd which doesn't share that
//     bug
//
// The model files (~520 MB) are bundled into the app under
//   Resources/BundledVLM/ggml-org_SmolVLM2-500M-Video-Instruct-GGUF/
//     SmolVLM2-500M-Video-Instruct-Q8_0.gguf          (LLM, ~417 MB)
//     mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf   (vision projector, ~104 MB)
//
// On first launch we copy them into the HFModels cache layout the
// llama.cpp service expects:
//   Documents/HFModels/ggml-org_SmolVLM2-500M-Video-Instruct-GGUF/
//
// LlamaCppVLMService.stagedDirectory(for:) finds them there
// without any HubApi round-trip; the model loads instantly.
//
// Idempotent: re-runs no-op when the destination already holds
// both GGUF files.

enum BundledVLMInstaller {

    /// HuggingFace repo id this bundle ships. Lens defaults point
    /// here via DeviceTierAdvisor.recommendedVisualModelRepoID.
    static let bundledRepoID = "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"

    /// Flattened folder name used in both bundle paths and on-disk
    /// destination (matches the convention HFModels/ uses).
    private static let bundleFolderName = "ggml-org_SmolVLM2-500M-Video-Instruct-GGUF"

    /// True when the bundled GGUF files are already on disk in the
    /// expected location. Skip the copy when true.
    static var isInstalled: Bool {
        let dir = hfModelsURL(forRepo: bundledRepoID)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        var hasLLM = false
        var hasMmproj = false
        for n in names where n.hasSuffix(".gguf") {
            if n.lowercased().hasPrefix("mmproj") { hasMmproj = true }
            else { hasLLM = true }
        }
        return hasLLM && hasMmproj
    }

    /// HFModels-format on-disk location for `repoID`. Matches
    /// LlamaCppVLMService.stagedDirectory's path probe (the
    /// flattened-folder candidate).
    static func hfModelsURL(forRepo repoID: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let flattened = repoID.replacingOccurrences(of: "/", with: "_")
        return docs
            .appendingPathComponent("HFModels", isDirectory: true)
            .appendingPathComponent(flattened, isDirectory: true)
    }

    /// Legacy: HubApi-style cache URL. Kept for any code that still
    /// references it (e.g. cleanup paths that delete the OLD MLX
    /// bundle on migration). The current install path is
    /// `hfModelsURL(forRepo:)`.
    static func hubCacheURL(forRepo repoID: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("huggingface")
            .appendingPathComponent("models")
            .appendingPathComponent(repoID)
    }

    /// One-shot install. Safe to call multiple times.
    @discardableResult
    static func installIfNeeded() -> Bool {
        guard !isInstalled else { return true }

        guard let bundleRoot = Bundle.main.resourceURL?
            .appendingPathComponent("BundledVLM")
            .appendingPathComponent(bundleFolderName) else {
            print("[BundledVLMInstaller] Bundle root not found")
            return false
        }
        guard FileManager.default.fileExists(atPath: bundleRoot.path) else {
            print("[BundledVLMInstaller] Bundle directory missing at \(bundleRoot.path) — lens tab will need network download of the GGUF pair")
            return false
        }

        let dest = hfModelsURL(forRepo: bundledRepoID)
        do {
            try FileManager.default.createDirectory(
                at: dest, withIntermediateDirectories: true
            )
        } catch {
            print("[BundledVLMInstaller] Failed to create HFModels dir: \(error)")
            return false
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: bundleRoot.path) else {
            print("[BundledVLMInstaller] Empty bundle directory")
            return false
        }

        var copiedAny = false
        for name in files {
            if name.hasPrefix(".") { continue }
            let src = bundleRoot.appendingPathComponent(name)
            let dst = dest.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            do {
                try fm.copyItem(at: src, to: dst)
                copiedAny = true
            } catch {
                print("[BundledVLMInstaller] Copy failed for \(name): \(error)")
                return false
            }
        }

        if copiedAny {
            print("[BundledVLMInstaller] Installed bundled SmolVLM2 GGUF (LLM + mmproj) into \(dest.path)")
        }

        // One-time cleanup: free disk by deleting the OLD MLX
        // SmolVLM2 cache if it still sits in HubApi's location
        // from a previous install. Saves ~1 GB on disk for users
        // upgrading from the pre-GGUF build.
        cleanupOldMLXBundle()

        return true
    }

    /// Remove the previous MLX SmolVLM2-Video-Instruct bundle from
    /// Documents/huggingface/models/ if present. Runs once per
    /// install. Not destructive of user-downloaded models (those
    /// live under HFModels/, not under the HubApi cache).
    private static func cleanupOldMLXBundle() {
        let oldRepo = "HuggingFaceTB/SmolVLM2-500M-Video-Instruct-mlx"
        let oldPath = hubCacheURL(forRepo: oldRepo)
        guard FileManager.default.fileExists(atPath: oldPath.path) else { return }
        do {
            try FileManager.default.removeItem(at: oldPath)
            print("[BundledVLMInstaller] Cleaned up old MLX SmolVLM2 cache at \(oldPath.path)")
        } catch {
            // Best effort; don't fail install over a cleanup miss.
            print("[BundledVLMInstaller] Old MLX cleanup skipped: \(error)")
        }
    }
}
