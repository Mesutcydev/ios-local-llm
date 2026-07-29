import Foundation

// MARK: - VoiceModelBundleValidator
// Checks whether KittenTTS or Kokoro model files are present on disk.
//
// Two search roots, probed in order:
//
//   1. `Bundle.main/BundledVoiceModels/…`    — shipped with the .app by
//      the "Copy bundled voice models" build step in project.yml. A
//      fresh install has working KittenTTS Nano + Kokoro-82M out of
//      the box; no download required.
//
//   2. `Documents/VoiceModels/…`             — written by
//      ModelDownloadCenter when the user opts into a different
//      variant (e.g. KittenTTS Mini, or a newer Kokoro CoreML export).
//
// Expected layout under either root:
//
//   KittenTTS/nano/kittentts_10s.mlmodelc/     (~62 MB, bundled default)
//   KittenTTS/nano/voices.npz
//   KittenTTS/mini/kittentts_mini_10s.mlmodelc/  (~280 MB, catalog-only)
//   KittenTTS/mini/voices.npz
//
//   Kokoro/kokoro_5s.mlmodelc/                 (~320 MB, bundled default)
//   Kokoro/G2PEncoder.mlmodelc/
//   Kokoro/G2PDecoder.mlmodelc/
//   Kokoro/voices/<voice>.json                 (~5 KB × 57 voices)
//   Kokoro/{config,pipeline_config,g2p_vocab,vocab_index}.json
//
// Run scripts/download_voice_models.sh only if you need to populate
// Documents/VoiceModels/ for development on a stripped build.

struct VoiceModelBundleValidator {

    // MARK: - Roots
    //
    // Two roots are probed in order:
    //
    //   1. `bundledVoiceModelsRoot()` — read-only directory inside the
    //      .app produced by the "Copy bundled voice models" build step
    //      in project.yml. Lets a fresh install ship with working
    //      KittenTTS + Kokoro out of the box, no Models → Catalog
    //      download required.
    //
    //   2. `voiceModelsRoot()` — writable directory under
    //      `Documents/VoiceModels/`, populated by ModelDownloadCenter
    //      when the user pulls a newer / different variant from the
    //      catalog. Takes precedence is intentionally NOT given here —
    //      we always prefer the bundled copy because it's signed with
    //      the app and is guaranteed to match the engine code. Adding
    //      a user-pinned override would mean keeping a Documents copy
    //      around forever after a catalog download even when the
    //      bundled file is identical; not worth the storage hit on a
    //      ~62 MB / ~320 MB pair.

    /// Returns the bundled voice models root if the build step copied
    /// it into the .app. Nil on stripped builds (or in tests that
    /// don't link the resource bundle).
    static func bundledVoiceModelsRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("BundledVoiceModels",
                                                     isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    /// Returns the writable voice models directory in the app's Documents
    /// folder. Used by ModelDownloadCenter as the destination for
    /// catalog downloads; probed second when resolving model URLs so a
    /// user-downloaded variant can still override the bundled one if
    /// the file layout happens to differ.
    static func voiceModelsRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("VoiceModels", isDirectory: true)
    }

    /// Probe order: bundled first, then Documents. Returns every candidate
    /// root that exists so the per-asset lookups can walk them uniformly.
    /// Kokoro's acoustic-model lookup overrides this (Documents first) so a
    /// catalog download wins over the incomplete bundled Kokoro folder.
    private static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let bundled = bundledVoiceModelsRoot() { roots.append(bundled) }
        roots.append(voiceModelsRoot())
        return roots
    }

    // MARK: - KittenTTS

    /// Returns the KittenTTS model URL if a recognised .mlmodelc is present.
    /// Layout on disk (matches the actual HF repo paths, used as allowlist
    /// in ModelDownloadCenter so the downloader produces this structure):
    ///   KittenTTS/nano/kittentts_10s.mlmodelc/
    ///   KittenTTS/mini/kittentts_mini_10s.mlmodelc/
    /// Returns nano first, mini second. Older builds shipped `.mlpackage`
    /// names — we still probe those for backwards-compatibility so users
    /// who downloaded under the old paths don't suddenly lose their model.
    static func kittenTTSModelURL() -> URL? {
        let candidates = [
            // Current naming: matches what the HF repo actually publishes.
            "nano/kittentts_10s.mlmodelc",
            "mini/kittentts_mini_10s.mlmodelc",
            // Legacy names — kept so prior installs still resolve.
            "kitten_tts_nano.mlpackage",
            "kitten_tts_mini.mlpackage",
        ]
        for root in searchRoots() {
            let dir = root.appendingPathComponent("KittenTTS", isDirectory: true)
            if let url = firstExistingDirectory(under: dir, relativePaths: candidates) {
                return url
            }
        }
        return nil
    }

    /// Returns the KittenTTS voices.npz URL if present. Sibling of whichever
    /// model variant resolved above — nano lives under `nano/`, mini under
    /// `mini/`. Falls back to the legacy flat `voices.npz` path if neither
    /// variant directory exists.
    static func kittenTTSVoicesURL() -> URL? {
        let candidates = [
            "nano/voices.npz",
            "mini/voices.npz",
            "voices.npz",                   // legacy flat path
        ]
        let fm = FileManager.default
        for root in searchRoots() {
            let dir = root.appendingPathComponent("KittenTTS", isDirectory: true)
            for relative in candidates {
                let url = dir.appendingPathComponent(relative)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// True when both the mlpackage and voices.npz are present for KittenTTS.
    static func isKittenTTSAvailable() -> Bool {
        let persisted = UserDefaults.standard.string(
            forKey: "voice.selectedKittenVariantID"
        )
        let selected = KittenManifest.configuration(
            for: KittenVariant(rawValue: persisted ?? "") ?? .nano08Int8
        )
        let officialInstalled = FileManager.default.fileExists(atPath: selected.modelURL.path)
            && FileManager.default.fileExists(atPath: selected.voiceDataURL.path)
        return officialInstalled || (kittenTTSModelURL() != nil && kittenTTSVoicesURL() != nil)
    }

    // MARK: - Kokoro
    //
    // Layout on disk after downloading aufklarer/Kokoro-82M-CoreML
    // (the catalog entry used by ModelDownloadCenter):
    //
    //   Kokoro/kokoro_5s.mlmodelc/        ← main acoustic model
    //   Kokoro/G2PEncoder.mlmodelc/       ← grapheme-to-phoneme encoder
    //   Kokoro/G2PDecoder.mlmodelc/       ← grapheme-to-phoneme decoder
    //   Kokoro/voices/<voice>.json        ← per-voice style vectors
    //   Kokoro/config.json
    //   Kokoro/pipeline_config.json
    //   Kokoro/g2p_vocab.json
    //   Kokoro/vocab_index.json
    //
    // The previous (manual-only) layout was `Kokoro/kokoro.mlpackage/`,
    // probed second so users who installed under the old script keep
    // working until they delete + re-download from the catalog.

    /// Returns the main Kokoro acoustic-model URL if present. Probes
    /// the current `.mlmodelc` shipped by `aufklarer/Kokoro-82M-CoreML`
    /// first, then a few common alternates (different sequence lengths
    /// other Kokoro forks publish), then the legacy `.mlpackage` name
    /// used by the old manual-download script.
    static func kokoroModelURL() -> URL? {
        let candidates = [
            // Current naming — aufklarer/Kokoro-82M-CoreML.
            "kokoro_5s.mlmodelc",
            // Alternates from FluidInference / other CoreML exports.
            "kokoro_24_15s.mlmodelc",
            "kokoro_24_10s.mlmodelc",
            "kokoro_21_15s.mlmodelc",
            "kokoro_21_10s.mlmodelc",
            "kokoro_21_5s.mlmodelc",
            // Legacy manual-install path.
            "kokoro.mlpackage",
            "kokoro.mlmodelc",
        ]
        // Documents first: the bundled Kokoro folder ships G2P + voices but
        // NOT `kokoro_5s.mlmodelc`. Preferring the bundle root would hide a
        // successful catalog download behind an incomplete install.
        var roots: [URL] = [voiceModelsRoot()]
        if let bundled = bundledVoiceModelsRoot() { roots.append(bundled) }
        for root in roots {
            let dir = root.appendingPathComponent("Kokoro", isDirectory: true)
            if let url = firstExistingDirectory(under: dir, relativePaths: candidates) {
                return url
            }
        }
        return nil
    }

    /// Returns the directory of per-voice style JSONs, if present.
    /// aufklarer ships them under `voices/`. Only required for the
    /// multi-voice pipeline — older single-voice exports omit it.
    static func kokoroVoicesDirectoryURL() -> URL? {
        let fm = FileManager.default
        for root in searchRoots() {
            let dir = root
                .appendingPathComponent("Kokoro", isDirectory: true)
                .appendingPathComponent("voices", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return nil
    }

    /// True only for a complete, usable Kokoro installation. Model discovery
    /// must not restore an engine whose acoustic model exists but whose voice
    /// metadata or phoneme vocabulary was deleted/corrupted.
    static func isKokoroAvailable() -> Bool {
        guard kokoroModelURL() != nil,
              let voicesDirectory = kokoroVoicesDirectoryURL(),
              containsDecodableJSON(in: voicesDirectory) else { return false }

        return searchRoots().contains { root in
            let vocabulary = root
                .appendingPathComponent("Kokoro", isDirectory: true)
                .appendingPathComponent("vocab_index.json")
            guard let data = try? Data(contentsOf: vocabulary),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = json as? [String: Any] else { return false }
            return !dictionary.isEmpty
        }
    }

    // MARK: - Silero VAD
    //
    // Voice-activity-detection model for the listening pipeline. Bundled
    // under Silero/silero_vad.mlmodelc — the pre-compiled CoreML conversion
    // from FluidInference/silero-vad-coreml (MIT). Single chunk in
    // (`audio_chunk` Float32 [1, 512] = 32 ms @ 16 kHz), one probability out
    // (`vad_probability` Float32 [1, 1]); no recurrent state to manage.

    /// Returns the Silero VAD model URL if the .mlmodelc is present.
    static func sileroVADModelURL() -> URL? {
        let candidates = ["silero_vad.mlmodelc"]
        for root in searchRoots() {
            let dir = root.appendingPathComponent("Silero", isDirectory: true)
            if let url = firstExistingDirectory(under: dir, relativePaths: candidates) {
                return url
            }
        }
        return nil
    }

    /// True when the Silero VAD model is on disk.
    static func isSileroVADAvailable() -> Bool {
        sileroVADModelURL() != nil
    }

    // MARK: - Helpers

    /// Returns the first relative path under `base` that resolves to a
    /// non-empty directory, or nil if none exist. .mlpackage / .mlmodelc
    /// artefacts are folders, so emptiness-checking the directory is
    /// the canonical "this model is actually here, not just a leftover
    /// shell" probe.
    private static func firstExistingDirectory(under base: URL,
                                               relativePaths: [String]) -> URL? {
        let fm = FileManager.default
        for relative in relativePaths {
            let url = base.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue,
               let contents = try? fm.contentsOfDirectory(atPath: url.path),
               !contents.isEmpty {
                // Compiled CoreML bundles always carry coremldata.bin at
                // their root — a non-empty but partially-downloaded
                // .mlmodelc must not count as installed.
                if url.pathExtension == "mlmodelc",
                   !fm.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path) {
                    continue
                }
                return url
            }
        }
        return nil
    }

    private static func containsDecodableJSON(in directory: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return false }
        return files.contains { url in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) else { return false }
            return json is [String: Any] || json is [Any]
        }
    }

    // MARK: - Diagnostics

    struct DiagnosticsReport {
        let kittenTTSModelFound: Bool
        let kittenTTSVoicesFound: Bool
        let kokoroModelFound: Bool
        /// Documents/VoiceModels/ path — writable, used by
        /// ModelDownloadCenter. Always non-nil even if the directory
        /// hasn't been created yet.
        let voiceModelsRootPath: String
        /// Bundle.main/BundledVoiceModels/ path if the build step
        /// copied it into the .app. Nil on stripped builds — useful
        /// signal when triaging "Voice mode shows download required
        /// on a build where it shouldn't."
        let bundledVoiceModelsRootPath: String?
    }

    static func diagnostics() -> DiagnosticsReport {
        DiagnosticsReport(
            kittenTTSModelFound: kittenTTSModelURL() != nil,
            kittenTTSVoicesFound: kittenTTSVoicesURL() != nil,
            kokoroModelFound: kokoroModelURL() != nil,
            voiceModelsRootPath: voiceModelsRoot().path,
            bundledVoiceModelsRootPath: bundledVoiceModelsRoot()?.path
        )
    }
}
