import AVFoundation
import CoreML
import Foundation
import CryptoKit

// MARK: - KittenTTSService
// On-device TTS backed by the KittenTTS CoreML model (alexwengg/kittentts-coreml).
//
// Architecture:
//   Text → PhonemizerEN (CMUdict → IPA phoneme IDs, upstream vocab)
//        → KittenTTS CoreML (Nano or Mini, 5s or 10s)
//        → Float32 PCM @ 24kHz
//
// Model files required. VoiceModelBundleValidator.kittenTTSModelURL()
// probes two roots in this order:
//
//   1. Bundle.main/BundledVoiceModels/KittenTTS/nano/kittentts_10s.mlmodelc/
//      + voices.npz   — shipped with the .app by the "Copy bundled
//      voice models" build step in project.yml. Default path on a
//      fresh install; no download required.
//   2. Documents/VoiceModels/KittenTTS/{nano,mini}/…   — populated by
//      ModelDownloadCenter when a user opts into the higher-quality
//      Mini variant from the catalog.
//
// scripts/download_voice_models.sh is a dev-only helper for the
// Documents path; production users never see it.
//
// History note. An earlier in-tree phonemizer (`BasicG2P`) used a 51-symbol
// hand-curated subset of the Kokoro symbol table, plus heuristic LTS rules.
// That produced phoneme IDs that DID NOT MATCH the model's training
// vocabulary — every id we sent decoded to a wrong symbol in the model's
// 178-symbol table, which produced a faded "robotic zombie" voice
// regardless of input text. The replacement (`PhonemizerEN`) reproduces the
// upstream Python `TextCleaner` symbol table byte for byte and looks up
// pronunciations in the bundled CMUdict.
//
// The CoreML model also expects a richer input feature set than the
// previous integration provided. Nano requires `input_ids` (fixed-length
// 70 or 140), `ref_s` (256-dim style), `random_phases` (9 floats),
// `attention_mask` (1 = valid token, 0 = padding), and `source_noise`
// (`[1, T, 9]` noise field). Mini swaps `random_phases`/`source_noise`
// for a `speed` scalar and uses `style` instead of `ref_s`, and the
// voice file is a 400×256 matrix (one row per token-count bin).
// Both shapes are inferred from `modelDescription.inputDescriptionsByName`
// at load time — there's no hardcoded variant assumption.

@MainActor
final class KittenTTSService: LocalVoiceEngine, ObservableObject {

    // MARK: - LocalVoiceEngine

    let kind: VoiceEngineKind = .kittenTTS
    @Published private(set) var modelState: VoiceModelState = .unloaded

    var isReady: Bool { modelState == .ready }

    // MARK: - Voices
    //
    // The voices.npz published by `alexwengg/kittentts-coreml` ships
    // exactly eight voices keyed `expr-voice-N-x` where N ∈ {2,3,4,5}
    // and x ∈ {m,f}. The previous voice list used Kokoro keys (`af`,
    // `af_bella`, `am_adam`, ...) which do not exist in this file —
    // every lookup fell through to `voiceEmbeddings["af"]` (also
    // missing), and synthesis would throw or run with whatever
    // happened to be in the dictionary. Names below are reassigned
    // by gender suffix; the upstream Python README pairs them
    // differently but appears to be a copy-paste artifact.

    static let kittenVoices: [VoiceOption] = [
        VoiceOption(id: "kitten:expr-voice-2-f", name: "Bella",  engineKind: .kittenTTS, locale: "en-US", description: "Female"),
        VoiceOption(id: "kitten:expr-voice-2-m", name: "Jasper", engineKind: .kittenTTS, locale: "en-US", description: "Male"),
        VoiceOption(id: "kitten:expr-voice-3-f", name: "Luna",   engineKind: .kittenTTS, locale: "en-US", description: "Female"),
        VoiceOption(id: "kitten:expr-voice-3-m", name: "Bruno",  engineKind: .kittenTTS, locale: "en-US", description: "Male"),
        VoiceOption(id: "kitten:expr-voice-4-f", name: "Rosie",  engineKind: .kittenTTS, locale: "en-US", description: "Female"),
        VoiceOption(id: "kitten:expr-voice-4-m", name: "Hugo",   engineKind: .kittenTTS, locale: "en-US", description: "Male"),
        VoiceOption(id: "kitten:expr-voice-5-f", name: "Kiki",   engineKind: .kittenTTS, locale: "en-US", description: "Female"),
        VoiceOption(id: "kitten:expr-voice-5-m", name: "Leo",    engineKind: .kittenTTS, locale: "en-US", description: "Male"),
    ]

    var availableVoices: [VoiceOption] { Self.kittenVoices }

    // MARK: - Private

    private var mlModel: MLModel?
    private var onnxEnvironment: ORTEnv?
    private var onnxSession: ORTSession?
    private var onnxConfiguration: KittenVariantConfiguration?
    /// Voice → 256-dim style vector (Nano) OR 400×256 matrix flattened
    /// row-major (Mini). Variant tells the synthesis path which to
    /// expect.
    private var voiceEmbeddings: [String: [Float]] = [:]
    private var variant: ModelVariant = .nano
    /// Phoneme sequence length the model expects (70 for 5s, 140 for
    /// 10s). Read once from the input description; serves as the
    /// zero-padding target.
    private var maxPhonemeTokens: Int = 140
    /// Source-noise time dimension `T` for Nano (typically 240000 for
    /// 10s model). Filled at load time from the model description.
    private var sourceNoiseTimeDim: Int = 0
    /// Cached Nano `source_noise` tensor. Regenerating ~2M Box-Muller
    /// samples on every utterance was a major Kitten lag source; the
    /// model only needs the right distribution, not a fresh draw each
    /// time. Cleared on unload.
    private var cachedSourceNoise: MLMultiArray?

    private enum ModelVariant {
        case nano, mini
    }

    // MARK: - Load

    func load() async {
        guard modelState != .ready, modelState != .loading else { return }
        modelState = .loading

        let selectedVariant = VoiceSettingsStore.shared.selectedKittenVariant
        let selectedConfiguration = KittenManifest.configuration(for: selectedVariant)
        if FileManager.default.fileExists(atPath: selectedConfiguration.modelURL.path),
           FileManager.default.fileExists(atPath: selectedConfiguration.voiceDataURL.path) {
            do {
                try Self.validateInstallation(selectedConfiguration)
                // ONNX 1.29 can include POSIX telemetry. Disable it before
                // creating the runtime environment, including in test hosts.
                guard setenv("ORT_DISABLE_TELEMETRY", "1", 1) == 0 else {
                    throw NSError(domain: "KittenTTS", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Could not disable runtime telemetry."])
                }
                let environment = try ORTEnv(loggingLevel: .warning)
                let options = try ORTSessionOptions()
                try options.setLogSeverityLevel(.warning)
                try options.setIntraOpNumThreads(2)
                let session = try ORTSession(
                    env: environment,
                    modelPath: selectedConfiguration.modelURL.path,
                    sessionOptions: options
                )
                let voiceData = try Data(contentsOf: selectedConfiguration.voiceDataURL)
                let embeddings = try NPZLoader.load(data: voiceData)
                guard !embeddings.isEmpty,
                      embeddings.values.allSatisfy({ $0.count >= 400 * 256 }) else {
                    throw VoiceError.synthesisFailedWithError(
                        "Official Kitten 0.8 voice embeddings are missing or malformed."
                    )
                }
                onnxEnvironment = environment
                onnxSession = session
                onnxConfiguration = selectedConfiguration
                voiceEmbeddings = embeddings
                modelState = .ready
                return
            } catch {
                onnxEnvironment = nil
                onnxSession = nil
                onnxConfiguration = nil
                voiceEmbeddings = [:]
                modelState = .failed(error.localizedDescription)
                return
            }
        }

        // Check model file presence. On a fresh install both files come
        // from Bundle.main/BundledVoiceModels/KittenTTS/nano/; the
        // Documents/ fallback only matters for users who pulled the
        // Mini variant from Models → Catalog.
        guard let modelURL = VoiceModelBundleValidator.kittenTTSModelURL() else {
            modelState = .failed(
                "KittenTTS model missing from the app bundle. " +
                "Reinstall the app, or open Models → Catalog to download a variant."
            )
            return
        }
        guard let voicesURL = VoiceModelBundleValidator.kittenTTSVoicesURL() else {
            modelState = .failed(
                "KittenTTS voices.npz missing from the app bundle. " +
                "Reinstall the app, or open Models → Catalog to re-download."
            )
            return
        }

        do {
            // The HF repo ships pre-compiled `.mlmodelc` packages — no need
            // (and not possible) to run MLModel.compileModel on them. Only
            // legacy `.mlpackage` artifacts need the compile step. Switch
            // on the path extension instead of forcing one code path.
            let isPrecompiled = modelURL.pathExtension == "mlmodelc"
            let loadURL: URL
            if isPrecompiled {
                loadURL = modelURL
            } else {
                loadURL = try await Task.detached(priority: .userInitiated) {
                    try MLModel.compileModel(at: modelURL)
                }.value
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: loadURL, configuration: config)
            mlModel = model

            // Variant + shapes are derived from the model description so
            // a swap from nano→mini (different .mlmodelc) Just Works.
            // `random_phases` is Nano-only; `speed` is Mini-only.
            let inputs = model.modelDescription.inputDescriptionsByName
            variant = inputs["random_phases"] != nil ? .nano : .mini

            if let inputIDs = inputs["input_ids"]?.multiArrayConstraint {
                // Shape is [1, N]. Pull N as the maxPhonemeTokens.
                let shape = inputIDs.shape
                if shape.count >= 2 { maxPhonemeTokens = shape[1].intValue }
            }
            if variant == .nano, let noise = inputs["source_noise"]?.multiArrayConstraint {
                // Shape is [1, T, 9]. Pull T.
                let shape = noise.shape
                if shape.count >= 2 { sourceNoiseTimeDim = shape[1].intValue }
            }

            // Voice embeddings — Nano has 256-dim vectors; Mini has
            // 400×256 matrices. Both keyed by `expr-voice-N-x`.
            voiceEmbeddings = try loadVoicesNPZ(from: voicesURL)

            // Validate the voice embeddings BEFORE flipping to .ready.
            // Earlier builds happily reported "ready" with an empty or
            // wrong-shape voices dictionary; synthesis would then throw
            // on every call and VoiceService would fall back to System
            // — but only AFTER producing a half-second of garbled
            // "zombie" audio from the first chunk. Catching the failure
            // here means the engine never even enters the synthesis
            // path and the picker shows a clear "failed" state.
            try validateVoiceEmbeddings(variant: variant)

            modelState = .ready
        } catch {
            // Wipe any partially-loaded state so a retry starts from a
            // clean slate. Without this, a half-loaded model could pass
            // `isReady` checks elsewhere via a stale `mlModel` reference.
            mlModel = nil
            voiceEmbeddings = [:]
            modelState = .failed(error.localizedDescription)
        }
    }

    /// Sanity-check the loaded voice table before we mark the engine
    /// ready. Fails fast on the two cases that historically produced
    /// the "robotic zombie voice" symptom — empty NPZ payload (the
    /// loader couldn't decode the archive) or the wrong-dim voice
    /// vectors (the upstream repo silently changed the embedding
    /// shape and our cached layout no longer matches).
    private func validateVoiceEmbeddings(variant: ModelVariant) throws {
        guard !voiceEmbeddings.isEmpty else {
            throw VoiceError.synthesisFailedWithError(
                "voices.npz produced no entries. The downloaded file may be corrupt or use an unsupported NPZ encoding."
            )
        }
        // Spot-check the first available embedding for the variant's
        // expected dimensions. We don't iterate the whole table — one
        // mismatched row means the table is from a different KittenTTS
        // release and every subsequent synthesis would be junk.
        guard let any = voiceEmbeddings.values.first else { return }
        switch variant {
        case .nano:
            guard any.count >= 256 else {
                throw VoiceError.synthesisFailedWithError(
                    "Nano voice vectors expected to be 256-dim but got \(any.count). The downloaded voices.npz may be from the Mini variant — re-download the Nano package."
                )
            }
        case .mini:
            guard any.count == 400 * 256 else {
                throw VoiceError.synthesisFailedWithError(
                    "Mini voice matrices expected to be 400×256 (102400) but got \(any.count). The downloaded voices.npz may be from the Nano variant — re-download the Mini package."
                )
            }
        }
    }

    func unload() {
        mlModel = nil
        onnxSession = nil
        onnxEnvironment = nil
        onnxConfiguration = nil
        voiceEmbeddings = [:]
        cachedSourceNoise = nil
        modelState = .unloaded
    }

    // MARK: - Synthesize

    func synthesize(
        text: String,
        voice: VoiceOption,
        settings: VoiceSynthesisSettings
    ) async throws -> VoiceSynthesisResult {
        if let session = onnxSession, let configuration = onnxConfiguration {
            return try await synthesizeONNX(
                text: text,
                voice: voice,
                settings: settings,
                session: session,
                configuration: configuration
            )
        }
        guard isReady, let model = mlModel else {
            throw VoiceError.engineNotReady("KittenTTS model not loaded.")
        }

        // 1. G2P: text → phoneme IDs using the upstream-matching
        //    vocabulary + CMUdict-backed phonemizer. Returns the
        //    sequence already framed `[$, ..., …, $]` — no extra
        //    BOS/EOS handling needed by the caller.
        let phonemeIDs = PhonemizerEN.shared.phonemeIDs(for: text)
        // Three leading/trailing framing tokens — sequence with zero
        // content phonemes is suspicious.
        guard phonemeIDs.count > 3 else {
            throw VoiceError.synthesisFailedWithError("Phonemizer produced no phonemes for input text.")
        }
        // Long inputs are truncated to the fixed model window. Real
        // chunking lives in `TextChunker`; this is a safety belt for
        // single calls that bypass the chunker.
        let trimmed: [Int32]
        if phonemeIDs.count > maxPhonemeTokens {
            // Keep the leading pad, fit the body, append `…` + `$`
            // so the model still sees a properly framed sequence.
            let body = Array(phonemeIDs[1 ..< maxPhonemeTokens - 2])
            trimmed = [PhonemizerEN.padTokenID]
                   + body
                   + [PhonemizerEN.endOfUtteranceTokenID, PhonemizerEN.padTokenID]
        } else {
            trimmed = phonemeIDs
        }

        // 2. Resolve voice key. IDs are `kitten:expr-voice-N-x`; the
        //    npz keys are bare `expr-voice-N-x`. Fall back to the
        //    first available entry so a stale picker selection
        //    doesn't dead-end.
        let voiceKey = voice.id.hasPrefix("kitten:")
            ? String(voice.id.dropFirst("kitten:".count))
            : voice.id
        let embedding = voiceEmbeddings[voiceKey]
            ?? voiceEmbeddings["expr-voice-2-f"]
            ?? voiceEmbeddings.values.first
            ?? []
        guard !embedding.isEmpty else {
            throw VoiceError.synthesisFailedWithError("Voice embedding not found for '\(voiceKey)'.")
        }

        // 3. Build the fixed-length input_ids + attention_mask. We
        //    zero-pad up to `maxPhonemeTokens`; the model needs the
        //    mask to know where the real phonemes end.
        let validLen = trimmed.count
        let paddedIDs  = try buildPaddedInt32Array(trimmed, length: maxPhonemeTokens)
        let attMask    = try buildAttentionMask(validLen: validLen, length: maxPhonemeTokens)

        // 4. Variant-specific inputs.
        var features: [String: MLFeatureValue] = [
            "input_ids":      MLFeatureValue(multiArray: paddedIDs),
            "attention_mask": MLFeatureValue(multiArray: attMask),
        ]

        switch variant {
        case .nano:
            // Nano 256-dim style — direct lookup.
            guard embedding.count >= 256 else {
                throw VoiceError.synthesisFailedWithError("Nano voice vector has wrong dim (\(embedding.count); expected 256).")
            }
            let style = try buildFloat32Array(Array(embedding.prefix(256)), shape: [1, 256])
            features["ref_s"] = MLFeatureValue(multiArray: style)
            features["random_phases"] = MLFeatureValue(
                multiArray: try buildRandomPhases()
            )
            features["source_noise"] = MLFeatureValue(
                multiArray: try buildSourceNoise(timeDim: sourceNoiseTimeDim)
            )

        case .mini:
            // Mini voice is a 400×256 matrix. Row index = clamped
            // phoneme count. This mirrors the upstream "select a row
            // based on the number of phoneme tokens (clamp 0-399)"
            // recipe from the model card.
            guard embedding.count == 400 * 256 else {
                throw VoiceError.synthesisFailedWithError("Mini voice matrix has wrong size (\(embedding.count); expected 102400).")
            }
            let row = min(max(validLen, 0), 399)
            let start = row * 256
            let slice = Array(embedding[start ..< start + 256])
            let style = try buildFloat32Array(slice, shape: [1, 256])
            features["style"] = MLFeatureValue(multiArray: style)
            // Speed must be a [1] FLOAT32 tensor. Clamped to a safe
            // range; the model's own ALBERT-encoder duration head
            // doesn't degrade gracefully outside ~0.6..1.5.
            let speed = max(0.6, min(1.5, settings.speed))
            let speedArr = try MLMultiArray(shape: [1], dataType: .float32)
            speedArr[0] = NSNumber(value: speed)
            features["speed"] = MLFeatureValue(multiArray: speedArr)
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: features)

        // 5. Run inference on a detached task — CoreML's prediction
        //    is synchronous and we don't want to block the main
        //    actor while the Neural Engine works.
        let output = try await Task.detached(priority: .userInitiated) {
            try model.prediction(from: provider)
        }.value

        // 6. Extract audio. The model writes a fixed-length buffer
        //    zero-padded past the actual generated audio; the real
        //    length is in `audio_length_samples`.
        guard let audioFeature = output.featureValue(for: "audio"),
              let audioArray = audioFeature.multiArrayValue else {
            throw VoiceError.synthesisFailedWithError("KittenTTS produced no audio output.")
        }
        let validSampleCount: Int = {
            if let len = output.featureValue(for: "audio_length_samples")?.multiArrayValue,
               len.count > 0 {
                return min(audioArray.count, max(0, len[0].intValue))
            }
            return audioArray.count
        }()

        let samples = extractFloatSamples(from: audioArray, count: validSampleCount)
        let sampleRate = VoiceEngineKind.kittenTTS.sampleRate

        // 6b. Preserve per-token predicted durations (frames). StyleTTS2 /
        //     Kitten CoreML exposes `pred_dur` [1, N] — previously discarded.
        let predDur = Self.extractPredDur(from: output, validCount: validLen)

        // 7. Speed control. Mini is handled by the model itself
        //    (we passed `speed` above); for Nano apply post-hoc
        //    linear-interpolation resampling.
        let speedFactor: Double = (variant == .nano && abs(settings.speed - 1.0) > 0.05)
            ? Double(settings.speed) : 1.0
        let finalSamples: [Float]
        if speedFactor != 1.0 {
            finalSamples = resample(samples, factor: speedFactor)
        } else {
            finalSamples = samples
        }

        guard let pcmBuffer = AudioPlaybackService.makeBuffer(
            from: finalSamples,
            sampleRate: sampleRate
        ) else {
            throw VoiceError.audioBufferCreationFailed
        }

        let duration = Double(finalSamples.count) / sampleRate
        // When Nano resamples for speed, frame→time mapping scales with
        // the same factor (faster speech → shorter word spans).
        var meta = SynthesisMetadata(
            phonemeIDs: trimmed,
            predictedDurationsFrames: predDur,
            validTokenCount: validLen,
            samplesPerFrame: nil,
            sourceText: text,
            engineKind: .kittenTTS
        )
        if speedFactor != 1.0, let frames = meta.predictedDurationsFrames {
            // Resampling shortens audio; reduce frame counts proportionally
            // so aligner hop (duration/sum(frames)) stays consistent.
            meta.predictedDurationsFrames = frames.map { $0 / Float(speedFactor) }
        }

        let alignment = PredDurWordAligner.align(
            text: text,
            phonemeIDs: trimmed,
            predDurFrames: meta.predictedDurationsFrames ?? [],
            validTokenCount: validLen,
            audioDuration: duration,
            timelineOffset: 0,
            utf16BaseOffset: 0
        )

        return VoiceSynthesisResult(
            pcmBuffer: pcmBuffer,
            sampleRate: sampleRate,
            duration: duration,
            engineKind: .kittenTTS,
            voiceID: voice.id,
            alignment: alignment,
            synthesisMetadata: meta
        )
    }

    /// Reads CoreML `pred_dur` as a flat Float array for the valid token prefix.
    private static func extractPredDur(from output: MLFeatureProvider, validCount: Int) -> [Float]? {
        guard let feature = output.featureValue(for: "pred_dur"),
              let array = feature.multiArrayValue,
              array.count > 0 else { return nil }
        let n = min(validCount, array.count)
        var frames: [Float] = []
        frames.reserveCapacity(n)
        for i in 0..<n {
            frames.append(array[i].floatValue)
        }
        return frames
    }

    private func synthesizeONNX(
        text: String,
        voice: VoiceOption,
        settings: VoiceSynthesisSettings,
        session: ORTSession,
        configuration: KittenVariantConfiguration
    ) async throws -> VoiceSynthesisResult {
        try Task.checkCancellation()
        let ids = PhonemizerEN.shared.phonemeIDs(for: text).map(Int64.init)
        guard ids.count > 3 else {
            throw VoiceError.synthesisFailedWithError("Phonemizer produced no tokens.")
        }

        let voiceKey = voice.id.hasPrefix("kitten:")
            ? String(voice.id.dropFirst("kitten:".count))
            : voice.id
        guard let matrix = voiceEmbeddings[voiceKey]
                ?? voiceEmbeddings["expr-voice-2-f"]
                ?? voiceEmbeddings.values.first,
              matrix.count >= 400 * 256 else {
            throw VoiceError.synthesisFailedWithError("Voice embedding is unavailable.")
        }
        let row = min(ids.count, 399)
        let style = Array(matrix[(row * 256)..<(row * 256 + 256)])
        let inputIDs = ids.withUnsafeBufferPointer { Data(buffer: $0) }
        let styleData = style.withUnsafeBufferPointer { Data(buffer: $0) }
        var speed = max(0.6, min(1.5, settings.speed))
        let speedData = Data(bytes: &speed, count: MemoryLayout<Float>.size)

        let inputs: [String: ORTValue] = [
            "input_ids": try ORTValue(
                tensorData: NSMutableData(data: inputIDs),
                elementType: .int64,
                shape: [1, NSNumber(value: ids.count)]
            ),
            "style": try ORTValue(
                tensorData: NSMutableData(data: styleData),
                elementType: .float,
                shape: [1, 256]
            ),
            "speed": try ORTValue(
                tensorData: NSMutableData(data: speedData),
                elementType: .float,
                shape: [1]
            ),
        ]

        let outputs = try await Task.detached(priority: .userInitiated) {
            try session.run(
                withInputs: inputs,
                outputNames: ["waveform"],
                runOptions: nil
            )
        }.value
        try Task.checkCancellation()
        guard let waveform = outputs["waveform"] else {
            throw VoiceError.synthesisFailedWithError("ONNX inference returned no waveform.")
        }
        let bytes = try waveform.tensorData() as Data
        guard bytes.count >= MemoryLayout<Float>.size else {
            throw VoiceError.synthesisFailedWithError("ONNX waveform is empty.")
        }
        let count = bytes.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        bytes.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Float.self)
            for index in 0..<count { samples[index] = values[index] }
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw VoiceError.synthesisFailedWithError("ONNX waveform contains NaN or infinity.")
        }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > 0.0001 else {
            throw VoiceError.synthesisFailedWithError("ONNX waveform is silent.")
        }
        guard let buffer = AudioPlaybackService.makeBuffer(
            from: samples,
            sampleRate: configuration.sampleRate
        ) else { throw VoiceError.audioBufferCreationFailed }
        // Official ONNX export only requests `waveform` — no pred_dur.
        // Downstream acoustic alignment uses the PCM buffer.
        return VoiceSynthesisResult(
            pcmBuffer: buffer,
            sampleRate: configuration.sampleRate,
            duration: Double(samples.count) / configuration.sampleRate,
            engineKind: .kittenTTS,
            voiceID: voice.id,
            alignment: nil,
            synthesisMetadata: SynthesisMetadata(
                phonemeIDs: ids.map(Int32.init),
                sourceText: text,
                engineKind: .kittenTTS
            )
        )
    }

    private static func validateInstallation(_ configuration: KittenVariantConfiguration) throws {
        for artifact in configuration.artifacts where artifact.required {
            let url = configuration.installedDirectory.appendingPathComponent(artifact.relativePath)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == artifact.expectedBytes else {
                throw VoiceError.modelNotFound("Invalid size for \(artifact.relativePath).")
            }
            let digest = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == artifact.sha256 else {
                throw VoiceError.modelNotFound("Checksum failed for \(artifact.relativePath).")
            }
        }
    }

    // MARK: - MLMultiArray helpers

    /// Zero-pads `ids` to `length` and wraps them in an
    /// `[1, length]` INT32 `MLMultiArray`.
    private func buildPaddedInt32Array(_ ids: [Int32], length: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: length)
        // Zero-fill then copy. `MLMultiArray.dataPointer` memory is
        // uninitialised on creation, so the explicit zero pass is
        // required to avoid garbage tokens in the padding region.
        for i in 0 ..< length { ptr[i] = 0 }
        let copy = min(ids.count, length)
        for i in 0 ..< copy { ptr[i] = ids[i] }
        return array
    }

    /// `[1, length]` INT32 mask: 1s for the first `validLen` tokens,
    /// 0s after.
    private func buildAttentionMask(validLen: Int, length: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let ptr = array.dataPointer.bindMemory(to: Int32.self, capacity: length)
        let cap = min(validLen, length)
        for i in 0 ..< cap   { ptr[i] = 1 }
        for i in cap ..< length { ptr[i] = 0 }
        return array
    }

    /// Generic `[shape]` FLOAT32 builder from a flat `[Float]`.
    private func buildFloat32Array(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        for i in 0 ..< values.count { ptr[i] = values[i] }
        return array
    }

    /// Random `[1, 9]` FLOAT32 — initial harmonic phases for Nano's
    /// source-filter generator. The model is robust to the seed
    /// itself but expects the field to be present.
    private func buildRandomPhases() throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 9], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 9)
        for i in 0 ..< 9 { ptr[i] = Float.random(in: -.pi ... .pi) }
        return array
    }

    /// `[1, T, 9]` FLOAT32 zero-mean Gaussian noise — Nano's
    /// source-noise field. `T` was read from the input description
    /// at load time (e.g. 240000 for the 10s nano model). Filling
    /// with N(0, 1) noise matches the distribution the model
    /// expects from upstream's torch.randn-based generator.
    ///
    /// Result is cached for the life of the loaded model — regenerating
    /// ~2.16M Box-Muller samples per utterance was a dominant Kitten lag
    /// source on Nano 10s. The model is robust to a fixed noise field.
    private func buildSourceNoise(timeDim T: Int) throws -> MLMultiArray {
        if let cached = cachedSourceNoise,
           cached.shape == [1, NSNumber(value: T), 9] {
            return cached
        }
        let n = T * 9
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: T), 9],
            dataType: .float32
        )
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: n)
        // Box-Muller for a quick normal sample; CoreML doesn't need
        // bit-exact reproduction here, just the right distribution.
        var i = 0
        while i < n {
            let u1 = max(Float.leastNonzeroMagnitude, Float.random(in: 0 ..< 1))
            let u2 = Float.random(in: 0 ..< 1)
            let r  = sqrtf(-2.0 * logf(u1))
            let z0 = r * cosf(2.0 * .pi * u2)
            ptr[i] = z0
            i += 1
            if i < n {
                let z1 = r * sinf(2.0 * .pi * u2)
                ptr[i] = z1
                i += 1
            }
        }
        cachedSourceNoise = array
        return array
    }

    /// Extracts the first `count` samples from `array`, treating the
    /// buffer as Float32.
    private func extractFloatSamples(from array: MLMultiArray, count: Int) -> [Float] {
        let n = min(count, array.count)
        guard n > 0 else { return [] }
        var samples = [Float](repeating: 0, count: n)
        // CRITICAL: honor the output's real dtype. Binding a float16- or
        // double-typed buffer to Float32 reinterprets the bytes and turns
        // speech into loud noise (the "synthetic signal" symptom). ANE-compiled
        // CoreML models frequently emit float16, so we can't assume float32.
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
            // Correct (if slower) NSNumber path for any other dtype —
            // covers the integer dtypes and anything added in future SDKs.
            for i in 0 ..< n { samples[i] = array[i].floatValue }
        }
        // Sanitize: a NaN/Inf sample becomes a click/blast through the speaker.
        for i in 0 ..< n where !samples[i].isFinite { samples[i] = 0 }
        return samples
    }

    // MARK: - Speed via resampling

    private func resample(_ samples: [Float], factor: Double) -> [Float] {
        let newCount = Int(Double(samples.count) / factor)
        guard newCount > 0 else { return samples }
        var result = [Float](repeating: 0, count: newCount)
        let scale = Double(samples.count) / Double(newCount)
        for i in 0..<newCount {
            let srcIdx = Double(i) * scale
            let lo = Int(srcIdx)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcIdx - Double(lo))
            result[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }
        return result
    }

    // MARK: - NPZ loader
    // voices.npz is a NumPy archive. We load it with a minimal NPZ parser
    // (ZIP + raw npy header parsing).

    private func loadVoicesNPZ(from url: URL) throws -> [String: [Float]] {
        // NPZ is a ZIP file where each entry is a .npy array
        // We use a simple parser — no external deps needed
        let data = try Data(contentsOf: url)
        return try NPZLoader.load(data: data)
    }
}

// MARK: - NPZLoader
// Minimal ZIP + NPY parser for voices.npz.
//
// Handles BOTH:
//   • STORED entries (compressionMethod 0)        — passthrough
//   • DEFLATE entries (compressionMethod 8)       — Compression framework
//
// numpy's `savez` and `savez_compressed` both default to DEFLATE inside
// the ZIP container; the prior version of this loader only accepted
// STORED entries and silently dropped every voice. That produced the
// "voices.npz produced no entries" load failure even though the file
// on disk was perfectly valid.
//
// NPY parsing supports format v1.0 (16-bit header length) AND v2.0/3.0
// (32-bit header length) so a future repo bump can't quietly break us
// the same way.

import Compression

struct NPZLoader {

    static func load(data: Data) throws -> [String: [Float]] {
        // Drive everything off the ZIP central directory, NOT the local
        // file headers. numpy's `savez_compressed` is built on Python's
        // `zipfile`, which writes local headers with `compressedSize = 0`
        // and the data-descriptor flag set — the real sizes live in a
        // trailer after the compressed bytes. A local-header-only walk
        // would read 0, advance 0 bytes, and exit with an empty dict
        // (which is precisely the "voices.npz produced no entries"
        // symptom). The central directory is the canonical source for
        // entry metadata and ALWAYS has the correct sizes.
        var result: [String: [Float]] = [:]

        guard let eocdOffset = findEOCD(in: data) else {
            print("[NPZLoader] no End-of-Central-Directory record found — file may be truncated or not a ZIP")
            return result
        }
        let numEntries = Int(
            UInt16(data[eocdOffset + 10]) | (UInt16(data[eocdOffset + 11]) << 8)
        )
        let centralDirOffset = Int(
            UInt32(data[eocdOffset + 16]) |
            (UInt32(data[eocdOffset + 17]) << 8) |
            (UInt32(data[eocdOffset + 18]) << 16) |
            (UInt32(data[eocdOffset + 19]) << 24)
        )

        var cursor = centralDirOffset
        for _ in 0..<numEntries {
            guard cursor + 46 <= data.count else { break }
            // Central directory file header signature: PK\x01\x02
            guard data[cursor] == 0x50, data[cursor + 1] == 0x4B,
                  data[cursor + 2] == 0x01, data[cursor + 3] == 0x02 else { break }

            let compressionMethod = UInt16(data[cursor + 10]) | (UInt16(data[cursor + 11]) << 8)
            let compressedSize = Int(
                UInt32(data[cursor + 20]) |
                (UInt32(data[cursor + 21]) << 8) |
                (UInt32(data[cursor + 22]) << 16) |
                (UInt32(data[cursor + 23]) << 24)
            )
            let uncompressedSize = Int(
                UInt32(data[cursor + 24]) |
                (UInt32(data[cursor + 25]) << 8) |
                (UInt32(data[cursor + 26]) << 16) |
                (UInt32(data[cursor + 27]) << 24)
            )
            let nameLen = Int(
                UInt16(data[cursor + 28]) | (UInt16(data[cursor + 29]) << 8)
            )
            let extraLenCD = Int(
                UInt16(data[cursor + 30]) | (UInt16(data[cursor + 31]) << 8)
            )
            let commentLen = Int(
                UInt16(data[cursor + 32]) | (UInt16(data[cursor + 33]) << 8)
            )
            let localHeaderOffset = Int(
                UInt32(data[cursor + 42]) |
                (UInt32(data[cursor + 43]) << 8) |
                (UInt32(data[cursor + 44]) << 16) |
                (UInt32(data[cursor + 45]) << 24)
            )
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { break }
            let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""

            // Walk into the local file header to find where the actual
            // payload bytes start (local header has its own extra-field
            // length that may differ from the central-directory copy).
            if localHeaderOffset + 30 <= data.count,
               data[localHeaderOffset] == 0x50, data[localHeaderOffset + 1] == 0x4B,
               data[localHeaderOffset + 2] == 0x03, data[localHeaderOffset + 3] == 0x04 {
                let localNameLen = Int(
                    UInt16(data[localHeaderOffset + 26]) |
                    (UInt16(data[localHeaderOffset + 27]) << 8)
                )
                let localExtraLen = Int(
                    UInt16(data[localHeaderOffset + 28]) |
                    (UInt16(data[localHeaderOffset + 29]) << 8)
                )
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
                let dataEnd = dataStart + compressedSize
                if dataEnd <= data.count, name.hasSuffix(".npy") {
                    let key = (name as NSString).deletingPathExtension
                    let raw = Data(data[dataStart..<dataEnd])
                    let payload: Data?
                    switch compressionMethod {
                    case 0:
                        payload = raw
                    case 8:
                        payload = inflateDeflate(raw, expectedSize: uncompressedSize)
                    default:
                        print("[NPZLoader] unsupported ZIP compression method \(compressionMethod) for \(name)")
                        payload = nil
                    }
                    if let payload, let floats = parseNPY(data: payload) {
                        result[key] = floats
                    } else if payload != nil {
                        print("[NPZLoader] entry \(name) decompressed but failed NPY parse (\(payload?.count ?? 0) bytes)")
                    }
                }
            }

            cursor = nameEnd + extraLenCD + commentLen
        }

        if result.isEmpty {
            print("[NPZLoader] central directory had \(numEntries) entries but none parsed into Float arrays")
        }
        return result
    }

    /// Scans backward from the end of the ZIP for the End-of-Central-
    /// Directory record signature (PK\x05\x06). EOCD is fixed at 22
    /// bytes minimum + an optional comment up to 64 KB, so the worst-
    /// case scan window is ~64 KB.
    private static func findEOCD(in data: Data) -> Int? {
        let minSize = 22
        guard data.count >= minSize else { return nil }
        let maxBack = min(data.count - minSize, 65_557)
        var i = data.count - minSize
        let lowerBound = data.count - minSize - maxBack
        while i >= lowerBound && i >= 0 {
            if data[i] == 0x50 && data[i + 1] == 0x4B &&
                data[i + 2] == 0x05 && data[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }

    /// Inflate a raw DEFLATE stream using Apple's Compression framework.
    /// `expectedSize` is the uncompressed size stored in the ZIP local
    /// header — used to size the output buffer up front so we don't
    /// reallocate. When the header says 0 (some writers do that and
    /// stash the real value in the data-descriptor trailer), we fall
    /// back to a generous 32× the compressed size with a 256 KB floor.
    private static func inflateDeflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard !compressed.isEmpty else { return nil }
        let capacity = expectedSize > 0
            ? expectedSize
            : max(256 * 1024, compressed.count * 32)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (outBytes: UnsafeMutableRawBufferPointer) -> Int in
            guard let outBase = outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compressed.withUnsafeBytes { (inBytes: UnsafeRawBufferPointer) -> Int in
                guard let inBase = inBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    outBase, capacity,
                    inBase, compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else {
            print("[NPZLoader] DEFLATE inflate produced 0 bytes (capacity=\(capacity), compressed=\(compressed.count))")
            return nil
        }
        output.removeSubrange(written..<output.count)
        return output
    }

    private static func parseNPY(data: Data) -> [Float]? {
        // NPY magic: \x93NUMPY
        guard data.count > 10,
              data[data.startIndex + 0] == 0x93,
              data[data.startIndex + 1] == 0x4E,
              data[data.startIndex + 2] == 0x55,
              data[data.startIndex + 3] == 0x4D,
              data[data.startIndex + 4] == 0x50,
              data[data.startIndex + 5] == 0x59 else { return nil }

        let majorVersion = data[data.startIndex + 6]
        // v1.0 stores header length as a 16-bit LE int at bytes 8..9.
        // v2.0+ promote it to a 32-bit LE int at bytes 8..11 so headers
        // longer than 65535 chars can survive. The prior parser
        // hard-coded the v1.0 layout; if upstream ever bumps to v2.0 the
        // dataOffset would land in the middle of the header and parse
        // garbage. Branch explicitly on the version byte.
        let headerLen: Int
        let dataOffset: Int
        if majorVersion >= 2 {
            guard data.count >= 12 else { return nil }
            headerLen = Int(
                UInt32(data[data.startIndex + 8]) |
                (UInt32(data[data.startIndex + 9]) << 8) |
                (UInt32(data[data.startIndex + 10]) << 16) |
                (UInt32(data[data.startIndex + 11]) << 24)
            )
            dataOffset = 12 + headerLen
        } else {
            headerLen = Int(
                UInt16(data[data.startIndex + 8]) |
                (UInt16(data[data.startIndex + 9]) << 8)
            )
            dataOffset = 10 + headerLen
        }
        guard dataOffset < data.count else { return nil }

        // Peek at the descr field for diagnostics. The HF repo ships
        // <f4 (float32) per the README, but historically the parser
        // would blindly treat any byte stream as float32 — log when
        // it doesn't match expectations so a future repo bump to
        // float16/64 surfaces in the console instead of producing
        // silently corrupt voice vectors.
        let headerRange = (data.startIndex + (majorVersion >= 2 ? 12 : 10))..<(data.startIndex + dataOffset)
        let headerString = String(data: data[headerRange], encoding: .utf8) ?? ""
        if !headerString.contains("'<f4'") && !headerString.contains("\"<f4\"") {
            print("[NPZLoader] non-<f4 dtype in NPY header (continuing as float32): \(headerString.prefix(80))")
        }

        let payloadStart = data.startIndex + dataOffset
        let payloadData  = data[payloadStart...]
        let floatCount = payloadData.count / 4
        guard floatCount > 0 else { return nil }

        var floats = [Float](repeating: 0, count: floatCount)
        payloadData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            floats.withUnsafeMutableBytes { dest in
                dest.baseAddress?.copyMemory(from: base, byteCount: floatCount * 4)
            }
        }
        return floats
    }
}
