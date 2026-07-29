import AVFoundation
import CoreML
import Foundation

// MARK: - KokoroTTSService
// Kokoro-82M CoreML text-to-speech engine.
//
// Model files required. VoiceModelBundleValidator.kokoroModelURL()
// probes two roots in this order:
//
//   1. Bundle.main/BundledVoiceModels/Kokoro/kokoro_5s.mlmodelc/
//      + G2PEncoder.mlmodelc/, G2PDecoder.mlmodelc/, voices/,
//        config.json, pipeline_config.json, g2p_vocab.json,
//        vocab_index.json   — shipped with the .app by the "Copy
//      bundled voice models" build step in project.yml (~320 MB).
//   2. Documents/VoiceModels/Kokoro/…   — populated by
//      ModelDownloadCenter for users who pull a different variant
//      from the catalog.
//
// The current bundled `kokoro_5s.mlmodelc` is NOT a one-input toy model.
// Its metadata declares:
//
//   input_ids       [1, 128] Int32
//   attention_mask  [1, 128] Int32
//   ref_s           [1, 256] Float32
//   speed           [1]      Float32
//   random_phases   [1, 9]   Float32
//
// Earlier code only passed `input_ids`, so synthesis could never succeed
// on the real asset we ship. This implementation mirrors the KittenTTS
// integration: phonemize via KokoroPhonemizer (vocab_index.json) →
// pad/mask → load per-voice embeddings from the bundled JSON files →
// infer → trim to `audio_length_samples`.
//
// CRITICAL: Kokoro uses its own phoneme vocabulary (vocab_index.json)
// which is DIFFERENT from the StyleTTS2 vocabulary used by
// PhonemizerEN (KittenTTS). Feeding KittenTTS vocab IDs to the Kokoro
// model decodes every token to the wrong phoneme symbol, producing
// silence or garbled audio. KokoroPhonemizer maps characters through
// vocab_index.json to produce the correct ID space.

@MainActor
final class KokoroTTSService: LocalVoiceEngine, ObservableObject {

    // MARK: - LocalVoiceEngine

    let kind: VoiceEngineKind = .kokoro
    @Published private(set) var modelState: VoiceModelState = .unloaded

    var isReady: Bool { modelState == .ready }

    // MARK: - Voices

    static let kokoroVoices: [VoiceOption] = [
        makeVoice("af_alloy"), makeVoice("af_aoede"), makeVoice("af_bella"),
        makeVoice("af_heart"), makeVoice("af_jessica"), makeVoice("af_kore"),
        makeVoice("af_nicole"), makeVoice("af_nova"), makeVoice("af_river"),
        makeVoice("af_sarah"), makeVoice("af_sky"), makeVoice("am_adam"),
        makeVoice("am_echo"), makeVoice("am_eric"), makeVoice("am_fenrir"),
        makeVoice("am_liam"), makeVoice("am_michael"), makeVoice("am_onyx"),
        makeVoice("am_puck"), makeVoice("am_santa"), makeVoice("bf_alice"),
        makeVoice("bf_emma"), makeVoice("bf_isabella"), makeVoice("bf_lily"),
        makeVoice("bm_daniel"), makeVoice("bm_fable"), makeVoice("bm_george"),
        makeVoice("bm_lewis"), makeVoice("ef_dora"), makeVoice("em_alex"),
        makeVoice("em_santa"), makeVoice("ff_siwis"), makeVoice("hf_alpha"),
        makeVoice("hf_beta"), makeVoice("hm_omega"), makeVoice("hm_psi"),
        makeVoice("if_sara"), makeVoice("im_nicola"), makeVoice("jf_alpha"),
        makeVoice("jf_gongitsune"), makeVoice("jf_nezumi"), makeVoice("jf_tebukuro"),
        makeVoice("jm_kumo"), makeVoice("pf_dora"), makeVoice("pm_alex"),
        makeVoice("pm_santa"), makeVoice("zf_xiaobei"), makeVoice("zf_xiaoni"),
        makeVoice("zf_xiaoxiao"), makeVoice("zf_xiaoyi"), makeVoice("zm_yunjian"),
        makeVoice("zm_yunxi"), makeVoice("zm_yunxia"), makeVoice("zm_yunyang"),
    ]

    var availableVoices: [VoiceOption] { Self.kokoroVoices }

    // MARK: - Private

    private var mlModel: MLModel?
    private var voiceEmbeddings: [String: [Float]] = [:]
    private var maxPhonemeTokens: Int = 128

    // MARK: - Load

    func load() async {
        guard modelState != .ready, modelState != .loading else { return }
        modelState = .loading

        guard let modelURL = VoiceModelBundleValidator.kokoroModelURL() else {
            modelState = .failed(
                "Kokoro model missing from the app bundle. " +
                "Reinstall the app, or open Models → Catalog to re-download."
            )
            return
        }

        do {
            // The aufklarer/Kokoro-82M-CoreML repo ships pre-compiled
            // `.mlmodelc` packages — MLModel.compileModel(at:) doesn't
            // accept those (it expects a .mlpackage source). Switch on
            // the extension so the right code path runs for each layout
            // the user can end up with on disk.
            let isPrecompiled = modelURL.pathExtension == "mlmodelc"
            let loadURL: URL
            if isPrecompiled {
                loadURL = modelURL
            } else {
                loadURL = try await Task.detached(priority: .userInitiated) {
                    try MLModel.compileModel(at: modelURL)
                }.value
            }

            // ANE compilation of this Kokoro model has been observed to
            // SIGSEGV deep inside CoreML on some iOS 27 devices (the crash
            // is recovered on the next launch by CrashReporter). A native
            // SIGSEGV can't be caught with try/catch, so we *survive* it
            // instead of catching it: loadModel(at:useNeuralEngine:) drops a
            // sentinel right before the native call and clears it on return.
            // If the sentinel is still on disk now, the previous ANE attempt
            // took the whole process down — so fall back to CPU-only, which
            // skips the ANE compiler path that crashed.
            //
            // The latch is time-bounded (24h): a forever-sticky CPU-only
            // flag after one bad ANE compile left users stuck on the slow
            // path across updates, and every load() re-logged the WARN.
            // After the cooldown we retry ANE once; another crash re-arms
            // the sentinel for another day.
            let aneCrashedPreviously = shouldAvoidNeuralEngine()
            if aneCrashedPreviously {
                Diagnostics.shared.warning(
                    "Kokoro ANE load crashed on a previous launch — loading CPU-only.",
                    category: "voice"
                )
            }

            let model = try await loadModel(at: loadURL, useNeuralEngine: !aneCrashedPreviously)
            mlModel = model

            if let inputIDs = model.modelDescription.inputDescriptionsByName["input_ids"]?.multiArrayConstraint {
                let shape = inputIDs.shape
                if shape.count >= 2 {
                    maxPhonemeTokens = shape[1].intValue
                }
            }

            voiceEmbeddings = try loadVoiceEmbeddings()
            try validateVoiceEmbeddings()
            modelState = .ready
        } catch {
            mlModel = nil
            voiceEmbeddings = [:]
            modelState = .failed(error.localizedDescription)
        }
    }

    func unload() {
        mlModel = nil
        voiceEmbeddings = [:]
        modelState = .unloaded
    }

    /// Disk flag marking that an ANE-backed load was in flight when the
    /// process last died. Honoured for 24 hours so we don't SIGSEGV-loop
    /// on every launch, then cleared so a later OS/CoreML fix can recover
    /// ANE. A clean ANE load also removes it (see `loadModel`).
    private var aneLoadSentinelURL: URL {
        Diagnostics.directory.appendingPathComponent("kokoro_ane_load.sentinel")
    }

    private static let aneSentinelCooldown: TimeInterval = 24 * 60 * 60

    /// True when a prior ANE load crashed and the cooldown hasn't elapsed.
    /// Also clears the latch after an app update so a new build can retry
    /// ANE (CoreML / OS fixes often land between TestFlight builds).
    private func shouldAvoidNeuralEngine() -> Bool {
        let url = aneLoadSentinelURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? ""
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let stamp = "\(currentVersion) (\(currentBuild))"
        if let data = try? Data(contentsOf: url),
           let recorded = String(data: data, encoding: .utf8),
           !recorded.isEmpty,
           recorded != stamp {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) >= Self.aneSentinelCooldown {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        return true
    }

    /// Builds the MLModel off the main thread. Loading (and ANE-compiling) a
    /// CoreML model is heavy and synchronous; doing it on the `@MainActor`
    /// also courts a watchdog kill. When `useNeuralEngine` is true we write
    /// the sentinel immediately before the native call and remove it on
    /// return, so a crash *inside* CoreML — which can't be caught — is
    /// detectable on the next launch (see `load()`). CPU-only loads touch no
    /// sentinel, leaving any prior crash flag intact.
    private func loadModel(at url: URL, useNeuralEngine: Bool) async throws -> MLModel {
        let sentinelURL = aneLoadSentinelURL
        if useNeuralEngine {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            let stamp = "\(version) (\(build))".data(using: .utf8)
            FileManager.default.createFile(atPath: sentinelURL.path, contents: stamp)
        }
        defer {
            if useNeuralEngine { try? FileManager.default.removeItem(at: sentinelURL) }
        }
        return try await Task.detached(priority: .userInitiated) {
            let config = MLModelConfiguration()
            config.computeUnits = useNeuralEngine ? .cpuAndNeuralEngine : .cpuOnly
            return try MLModel(contentsOf: url, configuration: config)
        }.value
    }

    // MARK: - Synthesize

    func synthesize(
        text: String,
        voice: VoiceOption,
        settings: VoiceSynthesisSettings
    ) async throws -> VoiceSynthesisResult {
        guard isReady, let model = mlModel else {
            throw VoiceError.engineNotReady("Kokoro model not loaded.")
        }

        // G2P via KokoroPhonemizer — produces token IDs from
        // vocab_index.json, framed with BOS(1)...EOS(2). This is
        // the CORRECT vocabulary for the Kokoro model; the old path
        // through PhonemizerEN produced StyleTTS2 vocabulary IDs
        // that decode to wrong symbols on this model.
        let phonemeIDs = KokoroPhonemizer.shared.phonemeIDs(for: text)
        guard phonemeIDs.count > 2 else {
            throw VoiceError.synthesisFailedWithError("Phonemizer produced no phonemes for input text.")
        }

        // Truncate or pad to the model's fixed 128-token window.
        // Sequence is already BOS(1)...EOS(2); padding fills
        // with 0 (pad_token_id) after EOS.
        let trimmed: [Int32]
        if phonemeIDs.count > maxPhonemeTokens {
            // Keep BOS, fit as much body as possible, keep EOS.
            trimmed = [phonemeIDs[0]]
                + Array(phonemeIDs[1 ..< maxPhonemeTokens - 1])
                + [phonemeIDs.last!]
        } else {
            trimmed = phonemeIDs
        }
        let validLen = trimmed.count
        let inputIDs = try buildPaddedInt32Array(trimmed, length: maxPhonemeTokens)
        let attentionMask = try buildAttentionMask(validLen: validLen, length: maxPhonemeTokens)

        let voiceKey = resolvedVoiceKey(for: voice)
        let embedding = voiceEmbeddings[voiceKey]
            ?? voiceEmbeddings["af_bella"]
            ?? voiceEmbeddings.values.first
            ?? []
        guard embedding.count >= 256 else {
            throw VoiceError.synthesisFailedWithError(
                "Kokoro voice embedding missing or wrong size for '\(voiceKey)'."
            )
        }
        let style = try buildFloat32Array(Array(embedding.prefix(256)), shape: [1, 256])
        let speed = try buildSpeedArray(settings.speed)
        let randomPhases = try buildRandomPhases()

        let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: inputIDs),
            "attention_mask": MLFeatureValue(multiArray: attentionMask),
            "ref_s": MLFeatureValue(multiArray: style),
            "speed": MLFeatureValue(multiArray: speed),
            "random_phases": MLFeatureValue(multiArray: randomPhases),
        ])

        let output = try await Task.detached(priority: .userInitiated) {
            try model.prediction(from: inputFeatures)
        }.value

        guard let arr = output.featureValue(for: "audio")?.multiArrayValue else {
            throw VoiceError.synthesisFailedWithError("Kokoro produced no audio output.")
        }
        let validSampleCount: Int = {
            if let len = output.featureValue(for: "audio_length_samples")?.multiArrayValue,
               len.count > 0 {
                return min(arr.count, max(0, len[0].intValue))
            }
            return arr.count
        }()
        let samples = extractFloatSamples(from: arr, count: validSampleCount)
        guard !samples.isEmpty else {
            throw VoiceError.synthesisFailedWithError("Kokoro produced an empty audio buffer.")
        }
        // Duration prediction is fused inside kokoro_*.mlmodelc and is not
        // exposed as a tensor — acoustic alignment runs downstream.
        return try makeResult(samples, voice: voice, sourceText: text)
    }

    private func makeResult(
        _ samples: [Float],
        voice: VoiceOption,
        sourceText: String
    ) throws -> VoiceSynthesisResult {
        let sampleRate = VoiceEngineKind.kokoro.sampleRate
        guard let pcmBuffer = AudioPlaybackService.makeBuffer(from: samples, sampleRate: sampleRate) else {
            throw VoiceError.audioBufferCreationFailed
        }
        return VoiceSynthesisResult(
            pcmBuffer: pcmBuffer,
            sampleRate: sampleRate,
            duration: Double(samples.count) / sampleRate,
            engineKind: .kokoro,
            voiceID: voice.id,
            alignment: nil,
            synthesisMetadata: SynthesisMetadata(
                phonemeIDs: nil,
                predictedDurationsFrames: nil,
                validTokenCount: nil,
                samplesPerFrame: 600,
                sourceText: sourceText,
                engineKind: .kokoro
            )
        )
    }

    private func validateVoiceEmbeddings() throws {
        guard !voiceEmbeddings.isEmpty else {
            throw VoiceError.synthesisFailedWithError(
                "Kokoro voice JSONs produced no embeddings. The bundled voices directory may be corrupt."
            )
        }
        guard let any = voiceEmbeddings.values.first, any.count >= 256 else {
            throw VoiceError.synthesisFailedWithError(
                "Kokoro voice embeddings expected 256 floats per voice."
            )
        }
    }

    private func loadVoiceEmbeddings() throws -> [String: [Float]] {
        guard let voicesDir = VoiceModelBundleValidator.kokoroVoicesDirectoryURL() else {
            throw VoiceError.modelNotFound("Kokoro voices directory missing.")
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: voicesDir,
            includingPropertiesForKeys: nil
        )
        var result: [String: [Float]] = [:]
        for file in files where file.pathExtension.lowercased() == "json" {
            let data = try Data(contentsOf: file)
            let decoded = try JSONDecoder().decode(KokoroVoiceFile.self, from: data)
            result[file.deletingPathExtension().lastPathComponent] = decoded.embedding
        }
        return result
    }

    private func resolvedVoiceKey(for voice: VoiceOption) -> String {
        let raw = voice.id.hasPrefix("kokoro:") ? String(voice.id.dropFirst("kokoro:".count)) : voice.id
        return raw == "default" ? "af_bella" : raw
    }

    private func buildPaddedInt32Array(_ ids: [Int32], length: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: length)
        for i in 0 ..< length { ptr[i] = 0 }
        let copy = min(ids.count, length)
        for i in 0 ..< copy { ptr[i] = ids[i] }
        return array
    }

    private func buildAttentionMask(validLen: Int, length: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let cap = min(validLen, length)
        for i in 0 ..< cap { ptr[i] = 1 }
        for i in cap ..< length { ptr[i] = 0 }
        return array
    }

    private func buildFloat32Array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        for i in 0 ..< values.count { ptr[i] = values[i] }
        return array
    }

    private func buildSpeedArray(_ speed: Float) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .float32)
        array[0] = NSNumber(value: max(0.6, min(1.5, speed)))
        return array
    }

    private func buildRandomPhases() throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 9], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 9)
        for i in 0 ..< 9 { ptr[i] = Float.random(in: -.pi ... .pi) }
        return array
    }

    /// Extracts PCM samples honoring the real Core ML dtype. Binding a
    /// float16 ANE buffer as Float32 reinterprets bytes into loud noise
    /// (the "synthetic / zombie" symptom). Matches KittenTTSService.
    private func extractFloatSamples(from array: MLMultiArray, count: Int) -> [Float] {
        let n = min(count, array.count)
        guard n > 0 else { return [] }
        var samples = [Float](repeating: 0, count: n)
        switch array.dataType {
        case .float32:
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for i in 0 ..< n { samples[i] = ptr[i] }
        case .float16:
            let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            for i in 0 ..< n { samples[i] = Float(ptr[i]) }
        case .double:
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            for i in 0 ..< n { samples[i] = Float(ptr[i]) }
        default:
            for i in 0 ..< n { samples[i] = array[i].floatValue }
        }
        for i in 0 ..< n where !samples[i].isFinite { samples[i] = 0 }
        return samples
    }

    private struct KokoroVoiceFile: Decodable {
        let embedding: [Float]
    }

    private static func makeVoice(_ key: String) -> VoiceOption {
        VoiceOption(
            id: "kokoro:\(key)",
            name: displayName(for: key),
            engineKind: .kokoro,
            locale: locale(for: key),
            description: styleDescription(for: key)
        )
    }

    private static func displayName(for key: String) -> String {
        key
            .split(separator: "_")
            .dropFirst()
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func locale(for key: String) -> String {
        switch key.prefix(1) {
        case "a": return "en-US"
        case "b": return "en-GB"
        case "e": return "es-ES"
        case "f": return "fr-FR"
        case "h": return "hi-IN"
        case "i": return "it-IT"
        case "j": return "ja-JP"
        case "p": return "pt-BR"
        case "z": return "zh-CN"
        default:  return "en-US"
        }
    }

    private static func styleDescription(for key: String) -> String? {
        let prefix = key.split(separator: "_").first.map(String.init) ?? ""
        switch prefix.last {
        case "f": return "Female"
        case "m": return "Male"
        default:  return nil
        }
    }
}
