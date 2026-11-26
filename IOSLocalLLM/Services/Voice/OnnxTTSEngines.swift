import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - ONNX TTS engines
//
// Two downloaded ONNX Runtime voices, same runtime as KittenTTS:
//
//   • Paradee-8M v1.2 (sahilmahendrakar, Apache-2.0) — an 8.5 MB int8 model
//     distilled from Kokoro-82M. English, four voices. Kokoro phoneme IDs
//     (KokoroPhonemizer) framed with pad 0 → one graph → 24 kHz audio.
//   • Supertonic 3 (Supertone, OpenRAIL-M) — 31 languages incl. Turkish.
//     Unicode text → duration predictor → text encoder → 8 flow-matching
//     steps → vocoder → 44.1 kHz audio. Mirrors the archived MIT reference
//     at github.com/supertone-oss-archive/supertonic (py/helper.py).

/// One process-wide ORT environment for these engines.
private let onnxEnvironment: ORTEnv? = {
    setenv("ORT_DISABLE_TELEMETRY", "1", 1)
    return try? ORTEnv(loggingLevel: .warning)
}()

private func makeSession(_ url: URL) throws -> ORTSession {
    guard let env = onnxEnvironment else {
        throw VoiceError.engineNotReady("ONNX Runtime could not start.")
    }
    let options = try ORTSessionOptions()
    try options.setLogSeverityLevel(.warning)
    try options.setIntraOpNumThreads(2)
    return try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
}

private func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ shape: [Int]) throws -> ORTValue {
    let data = values.withUnsafeBufferPointer { NSMutableData(data: Data(buffer: $0)) }
    return try ORTValue(tensorData: data, elementType: type, shape: shape.map { NSNumber(value: $0) })
}

private func floats(_ value: ORTValue) throws -> [Float] {
    let bytes = try value.tensorData() as Data
    return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

/// Runs `session` and returns its first (only) output.
private func runFirst(_ session: ORTSession, _ inputs: [String: ORTValue]) throws -> ORTValue {
    guard let name = try session.outputNames().first,
          let output = try session.run(withInputs: inputs, outputNames: [name], runOptions: nil)[name] else {
        throw VoiceError.synthesisFailedWithError("ONNX model returned no output.")
    }
    return output
}

@MainActor
private func pcmResult(_ samples: [Float], rate: Double, kind: VoiceEngineKind,
                       voice: VoiceOption) throws -> VoiceSynthesisResult {
    guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
        throw VoiceError.synthesisFailedWithError("The voice model produced invalid audio.")
    }
    guard let buffer = AudioPlaybackService.makeBuffer(from: samples, sampleRate: rate) else {
        throw VoiceError.audioBufferCreationFailed
    }
    return VoiceSynthesisResult(pcmBuffer: buffer, sampleRate: rate,
                                duration: Double(samples.count) / rate,
                                engineKind: kind, voiceID: voice.id)
}

// MARK: - Paradee-8M

@MainActor
final class ParadeeTTSService: LocalVoiceEngine, ObservableObject {

    let kind: VoiceEngineKind = .paradee
    @Published private(set) var modelState: VoiceModelState = .unloaded
    var isReady: Bool { modelState == .ready }

    nonisolated static var directory: URL {
        VoiceModelBundleValidator.voiceModelsRoot().appendingPathComponent("Paradee", isDirectory: true)
    }
    nonisolated static var modelURL: URL { directory.appendingPathComponent("onnx/paradee_int8.onnx") }
    nonisolated static var configURL: URL { directory.appendingPathComponent("config.json") }
    nonisolated static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
            && FileManager.default.fileExists(atPath: configURL.path)
    }

    /// Order matches the model's `voice` index input.
    static let paradeeVoices: [VoiceOption] = [
        ("af_heart", "Heart", "en-US"), ("bf_isabella", "Isabella", "en-GB"),
        ("am_puck", "Puck", "en-US"), ("bm_fable", "Fable", "en-GB"),
    ].map { VoiceOption(id: "paradee:\($0.0)", name: $0.1, engineKind: .paradee,
                        locale: $0.2, description: "Paradee 8M") }
    var availableVoices: [VoiceOption] { Self.paradeeVoices }

    private var session: ORTSession?

    func load() async {
        guard !isReady else { return }
        guard Self.isAvailable else {
            modelState = .failed("Paradee is not downloaded.")
            return
        }
        modelState = .loading
        do {
            let url = Self.modelURL
            session = try await Task.detached(priority: .userInitiated) { try makeSession(url) }.value
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func unload() {
        session = nil
        modelState = .unloaded
    }

    func synthesize(text: String, voice: VoiceOption,
                    settings: VoiceSynthesisSettings) async throws -> VoiceSynthesisResult {
        guard let session else { throw VoiceError.engineNotReady("Paradee is not loaded.") }
        // KokoroPhonemizer frames with 1/2 for the Core ML export; Paradee,
        // like upstream Kokoro, frames with the pad token 0 and takes ≤510.
        let body = KokoroPhonemizer.shared.phonemeIDs(for: text).dropFirst().dropLast().prefix(510)
        guard !body.isEmpty else {
            throw VoiceError.synthesisFailedWithError("Phonemizer produced no phonemes for input text.")
        }
        let ids = [Int64(0)] + body.map(Int64.init) + [0]
        let voiceIndex = Int64(Self.paradeeVoices.firstIndex { $0.id == voice.id } ?? 0)
        let speed = max(0.5, min(2.0, settings.speed))
        let inputs: [String: ORTValue] = [
            "input_ids": try tensor(ids, .int64, [1, ids.count]),
            "speed": try tensor([speed], .float, [1]),
            "voice": try tensor([voiceIndex], .int64, [1]),
        ]
        let samples = try await Task.detached(priority: .userInitiated) {
            try floats(runFirst(session, inputs))
        }.value
        try Task.checkCancellation()
        return try pcmResult(samples, rate: 24_000, kind: .paradee, voice: voice)
    }
}

// MARK: - Supertonic 3

@MainActor
final class SupertonicTTSService: LocalVoiceEngine, ObservableObject {

    let kind: VoiceEngineKind = .supertonic
    @Published private(set) var modelState: VoiceModelState = .unloaded
    var isReady: Bool { modelState == .ready }

    nonisolated static var directory: URL {
        VoiceModelBundleValidator.voiceModelsRoot().appendingPathComponent("Supertonic", isDirectory: true)
    }
    nonisolated private static let graphNames = ["duration_predictor", "text_encoder", "vector_estimator", "vocoder"]
    nonisolated static var isAvailable: Bool {
        let fm = FileManager.default
        let onnx = directory.appendingPathComponent("onnx")
        return graphNames.allSatisfy { fm.fileExists(atPath: onnx.appendingPathComponent("\($0).onnx").path) }
            && fm.fileExists(atPath: onnx.appendingPathComponent("tts.json").path)
            && fm.fileExists(atPath: onnx.appendingPathComponent("unicode_indexer.json").path)
            && fm.fileExists(atPath: directory.appendingPathComponent("voice_styles/M1.json").path)
    }

    /// Languages Supertonic 3 reads (its `<lang>` text tags).
    nonisolated static let languages: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu",
        "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]
    static let supertonicVoices: [VoiceOption] =
        ((1...5).map { ("F\($0)", "Female \($0)") } + (1...5).map { ("M\($0)", "Male \($0)") })
        .map { VoiceOption(id: "supertonic:\($0.0)", name: $0.1, engineKind: .supertonic,
                           locale: "mul", description: "Supertonic 3 · 31 languages") }
    var availableVoices: [VoiceOption] { Self.supertonicVoices }

    /// Default denoising steps and speed from the reference implementation.
    nonisolated private static let totalSteps = 8
    nonisolated private static let baseSpeed: Float = 1.05
    /// Weights total ~400 MB; ORT arenas roughly double that while running.
    private static let estimatedFootprint: Int64 = 900_000_000

    private struct Runtime {
        let durationPredictor: ORTSession, textEncoder: ORTSession
        let vectorEstimator: ORTSession, vocoder: ORTSession
        let indexer: [Int64]
        let sampleRate: Int, chunkSize: Int, latentChannels: Int
    }
    private struct Style { let ttl: [Float], ttlShape: [Int], dp: [Float], dpShape: [Int] }

    private var runtime: Runtime?
    private var styles: [String: Style] = [:]

    func load() async {
        guard !isReady else { return }
        guard Self.isAvailable else {
            modelState = .failed("Supertonic is not downloaded.")
            return
        }
        // Same admission rule as the other heavy runtimes: refuse rather than
        // risk a jetsam; VoiceService then speaks with the Apple voice.
        let needed = Self.estimatedFootprint + MemoryAdvisor.loadHeadroomReserve
        guard MemoryAdvisor.availableMemoryForModel >= needed else {
            modelState = .failed("Not enough free memory for Supertonic right now.")
            return
        }
        modelState = .loading
        do {
            let dir = Self.directory
            runtime = try await Task.detached(priority: .userInitiated) { try Self.makeRuntime(dir) }.value
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    func unload() {
        runtime = nil
        styles = [:]
        modelState = .unloaded
    }

    nonisolated private static func makeRuntime(_ dir: URL) throws -> Runtime {
        let onnx = dir.appendingPathComponent("onnx")
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: onnx.appendingPathComponent("tts.json"))) as? [String: Any]
        let ae = cfg?["ae"] as? [String: Any], ttl = cfg?["ttl"] as? [String: Any]
        guard let sampleRate = ae?["sample_rate"] as? Int, let baseChunk = ae?["base_chunk_size"] as? Int,
              let compress = ttl?["chunk_compress_factor"] as? Int, let latentDim = ttl?["latent_dim"] as? Int,
              let indexer = try JSONSerialization.jsonObject(
                with: Data(contentsOf: onnx.appendingPathComponent("unicode_indexer.json"))) as? [NSNumber]
        else { throw VoiceError.modelNotFound("Supertonic configuration is malformed.") }
        func session(_ name: String) throws -> ORTSession {
            try makeSession(onnx.appendingPathComponent("\(name).onnx"))
        }
        return Runtime(durationPredictor: try session("duration_predictor"), textEncoder: try session("text_encoder"),
                       vectorEstimator: try session("vector_estimator"), vocoder: try session("vocoder"),
                       indexer: indexer.map(\.int64Value), sampleRate: sampleRate,
                       chunkSize: baseChunk * compress, latentChannels: latentDim * compress)
    }

    func synthesize(text: String, voice: VoiceOption,
                    settings: VoiceSynthesisSettings) async throws -> VoiceSynthesisResult {
        guard let runtime else { throw VoiceError.engineNotReady("Supertonic is not loaded.") }
        let styleName = voice.id.hasPrefix("supertonic:") ? String(voice.id.dropFirst("supertonic:".count)) : "M1"
        let style = try loadStyle(styleName)
        let lang = Self.language(for: text)
        let speed = Self.baseSpeed * max(0.5, min(2.0, settings.speed))
        let chunks = Self.chunks(text, maxLength: lang == "ko" || lang == "ja" ? 120 : 300)

        let samples = try await Task.detached(priority: .userInitiated) {
            var audio: [Float] = []
            for chunk in chunks {
                try Task.checkCancellation()
                if !audio.isEmpty { audio += [Float](repeating: 0, count: runtime.sampleRate * 3 / 10) }
                audio += try Self.infer(chunk, lang: lang, style: style, speed: speed, runtime: runtime)
            }
            return audio
        }.value
        try Task.checkCancellation()
        return try pcmResult(samples, rate: Double(runtime.sampleRate), kind: .supertonic, voice: voice)
    }

    nonisolated private static func infer(_ text: String, lang: String, style: Style,
                                          speed: Float, runtime: Runtime) throws -> [Float] {
        let ids: [Int64] = preprocess(text, lang: lang).unicodeScalars.compactMap {
            let v = Int($0.value)
            return v < runtime.indexer.count && runtime.indexer[v] >= 0 ? runtime.indexer[v] : nil
        }
        guard !ids.isEmpty else { throw VoiceError.synthesisFailedWithError("No speakable text.") }
        let textIDs = try tensor(ids, .int64, [1, ids.count])
        let textMask = try tensor([Float](repeating: 1, count: ids.count), .float, [1, 1, ids.count])
        let styleTTL = try tensor(style.ttl, .float, style.ttlShape)
        let styleDP = try tensor(style.dp, .float, style.dpShape)

        let duration = try floats(runFirst(runtime.durationPredictor,
            ["text_ids": textIDs, "style_dp": styleDP, "text_mask": textMask])).first ?? 0
        let textEmb = try runFirst(runtime.textEncoder,
            ["text_ids": textIDs, "style_ttl": styleTTL, "text_mask": textMask])

        let wavLength = Int(Double(duration / speed) * Double(runtime.sampleRate))
        let latentLength = max(1, (wavLength + runtime.chunkSize - 1) / runtime.chunkSize)
        let latentShape = [1, runtime.latentChannels, latentLength]
        var latent = (0..<(runtime.latentChannels * latentLength)).map { _ in gaussian() }
        let latentMask = try tensor([Float](repeating: 1, count: latentLength), .float, [1, 1, latentLength])
        let totalStep = try tensor([Float(totalSteps)], .float, [1])
        for step in 0..<totalSteps {
            latent = try floats(runFirst(runtime.vectorEstimator, [
                "noisy_latent": try tensor(latent, .float, latentShape), "text_emb": textEmb,
                "style_ttl": styleTTL, "text_mask": textMask, "latent_mask": latentMask,
                "current_step": try tensor([Float(step)], .float, [1]), "total_step": totalStep,
            ]))
        }
        let wav = try floats(runFirst(runtime.vocoder, ["latent": try tensor(latent, .float, latentShape)]))
        return Array(wav.prefix(max(wavLength, 1)))
    }

    /// The reference text normalizer: NFKD, no emoji, simple symbol
    /// rewrites, final punctuation, then `<lang>` tags.
    nonisolated static func preprocess(_ text: String, lang: String) -> String {
        var t = text.decomposedStringWithCompatibilityMapping
        t.unicodeScalars.removeAll { $0.properties.isEmojiPresentation || (0x2600...0x27BF).contains($0.value) }
        let replacements: [(String, String)] = [
            ("–", "-"), ("‑", "-"), ("—", "-"), ("_", " "), ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2018}", "'"), ("\u{2019}", "'"), ("´", "'"), ("`", "'"), ("[", " "), ("]", " "),
            ("|", " "), ("/", " "), ("#", " "), ("→", " "), ("←", " "), ("♥", ""), ("☆", ""),
            ("♡", ""), ("©", ""), ("\\", ""), ("@", " at "), ("e.g.,", "for example, "), ("i.e.,", "that is, "),
        ]
        for (from, to) in replacements { t = t.replacingOccurrences(of: from, with: to) }
        for mark in [",", ".", "!", "?", ";", ":", "'"] { t = t.replacingOccurrences(of: " " + mark, with: mark) }
        while t.contains("\"\"") { t = t.replacingOccurrences(of: "\"\"", with: "\"") }
        while t.contains("''") { t = t.replacingOccurrences(of: "''", with: "'") }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let last = t.last, !".!?;:,'\")]}…。」』】〉》›»".contains(last) { t += "." }
        return "<\(lang)>\(t)</\(lang)>"
    }

    /// Detected language when Supertonic reads it, else the device language, else English.
    nonisolated static func language(for text: String) -> String {
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue.prefix(2).lowercased()
        let device = Locale.current.language.languageCode?.identifier
        return [detected, device].compactMap { $0 }.first { languages.contains($0) } ?? "en"
    }

    /// Sentence-packed chunks of at most `maxLength` characters.
    nonisolated static func chunks(_ text: String, maxLength: Int) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { sentences.append(s) }
        }
        var result: [String] = []
        for sentence in sentences {
            if let last = result.last, last.count + sentence.count + 1 <= maxLength {
                result[result.count - 1] = last + " " + sentence
            } else {
                result.append(sentence)
            }
        }
        return result.isEmpty ? [text] : result
    }

    private func loadStyle(_ name: String) throws -> Style {
        if let cached = styles[name] { return cached }
        let url = Self.directory.appendingPathComponent("voice_styles/\(name).json")
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let ttl = json["style_ttl"] as? [String: Any], let dp = json["style_dp"] as? [String: Any],
              let ttlShape = (ttl["dims"] as? [NSNumber])?.map(\.intValue),
              let dpShape = (dp["dims"] as? [NSNumber])?.map(\.intValue) else {
            throw VoiceError.modelNotFound("Supertonic voice \(name) is malformed.")
        }
        let style = Style(ttl: Self.flatten(ttl["data"]), ttlShape: ttlShape,
                          dp: Self.flatten(dp["data"]), dpShape: dpShape)
        styles[name] = style
        return style
    }

    private static func flatten(_ value: Any?) -> [Float] {
        if let number = value as? NSNumber { return [number.floatValue] }
        return (value as? [Any])?.flatMap { flatten($0) } ?? []
    }

    /// Standard normal sample (Box–Muller).
    nonisolated private static func gaussian() -> Float {
        let u1 = Float.random(in: Float.ulpOfOne..<1), u2 = Float.random(in: 0..<1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

#if targetEnvironment(macCatalyst)
// ponytail: ONNX Runtime ships no Mac Catalyst slice, so the Mac build links
// none of it (see Podfile). These stand-ins cover the API the ONNX voices use;
// creating the environment throws, so KittenTTS, Paradee and Supertonic fail
// to load on Mac with a clear message. Replace with the real runtime once a
// Catalyst onnxruntime.xcframework exists.
private let onnxUnavailableOnMac = VoiceError.engineNotReady("ONNX voices are not available on Mac.")

enum ORTLoggingLevel { case warning }
enum ORTTensorElementDataType { case int64, float }
final class ORTRunOptions {}

final class ORTEnv {
    init(loggingLevel: ORTLoggingLevel) throws { throw onnxUnavailableOnMac }
}

final class ORTSessionOptions {
    init() throws {}
    func setLogSeverityLevel(_ level: ORTLoggingLevel) throws {}
    func setIntraOpNumThreads(_ count: Int32) throws {}
}

final class ORTSession {
    init(env: ORTEnv, modelPath: String, sessionOptions: ORTSessionOptions) throws { throw onnxUnavailableOnMac }
    func outputNames() throws -> [String] { throw onnxUnavailableOnMac }
    func run(withInputs inputs: [String: ORTValue], outputNames: Set<String>,
             runOptions: ORTRunOptions?) throws -> [String: ORTValue] { throw onnxUnavailableOnMac }
}

final class ORTValue {
    init(tensorData: NSMutableData, elementType: ORTTensorElementDataType, shape: [NSNumber]) throws {
        throw onnxUnavailableOnMac
    }
    func tensorData() throws -> NSMutableData { throw onnxUnavailableOnMac }
}
#endif
