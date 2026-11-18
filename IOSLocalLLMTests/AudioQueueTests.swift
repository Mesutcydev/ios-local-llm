import AVFoundation
import XCTest
@testable import IOSLocalLLM

// MARK: - AudioQueueTests
//
// Pins the producer-consumer queue that drives streaming TTS playback.
// Lifted from `StreamingSpeechSession` and renamed; the suspension
// semantics and the cancellation contract (synchronous `stop`, no
// fadeout) must remain bit-for-bit identical to the previous behavior.

@MainActor
final class AudioQueueTests: XCTestCase {

    // MARK: - enqueue / next basics

    func test_enqueueOnce_nextReturnsImmediately() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "hello"))
        let item = await q.next()
        XCTAssertEqual(item?.text, "hello")
    }

    func test_enqueueTrimsWhitespace() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "  trimmed  "))
        let item = await q.next()
        XCTAssertEqual(item?.text, "trimmed")
    }

    func test_enqueueEmptyDropped() async {
        let q = AudioQueue()
        q.enqueue(.init(text: ""))
        q.enqueue(.init(text: "   "))
        q.enqueue(.init(text: "real"))
        let item = await q.next()
        XCTAssertEqual(item?.text, "real")
    }

    func test_enqueueDoesNotInterrupt_queueDepthReflectsPending() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "first"))
        q.enqueue(.init(text: "second"))
        q.enqueue(.init(text: "third"))
        // Consumer hasn't pulled yet — 3 pending, but `next()` will
        // dequeue immediately when called. Verify depth post-dequeue.
        let item = await q.next()
        XCTAssertEqual(item?.text, "first")
        XCTAssertEqual(q.queueDepth, 2,
                       "After dequeueing first, two remain pending")
    }

    func test_languageTagRoundtrips() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "Merhaba.", language: "tr-TR"))
        let item = await q.next()
        XCTAssertEqual(item?.language, "tr-TR")
    }

    func test_engineHintRoundtrips() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "code-only", language: nil, engineHint: .appleSystem))
        let item = await q.next()
        XCTAssertEqual(item?.engineHint, .appleSystem)
    }

    // MARK: - Observable state

    func test_isSpeakingTogglesAroundConsumer() async {
        let q = AudioQueue()
        XCTAssertFalse(q.isSpeaking)
        q.enqueue(.init(text: "first", language: "en-US"))
        _ = await q.next()
        XCTAssertTrue(q.isSpeaking, "Dequeue marks the queue as speaking")
        XCTAssertEqual(q.currentLanguage, "en-US")

        // Finish + drain → next() returns nil → speaking flips off.
        q.finish()
        let tail = await q.next()
        XCTAssertNil(tail)
        XCTAssertFalse(q.isSpeaking)
        XCTAssertNil(q.currentLanguage)
    }

    func test_currentLanguageReflectsActiveUtterance() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "Hello.", language: "en-US"))
        q.enqueue(.init(text: "Merhaba.", language: "tr-TR"))
        _ = await q.next()
        XCTAssertEqual(q.currentLanguage, "en-US")
        _ = await q.next()
        XCTAssertEqual(q.currentLanguage, "tr-TR")
    }

    // MARK: - finish() — drain all to completion

    func test_finishLetsAllPendingDrain() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "one"))
        q.enqueue(.init(text: "two"))
        q.finish()
        let first  = await q.next()
        let second = await q.next()
        let third  = await q.next()
        XCTAssertEqual(first?.text,  "one")
        XCTAssertEqual(second?.text, "two")
        XCTAssertNil(third, "After draining, next() returns nil")
    }

    // MARK: - drainPending() — drop queued, let current finish

    func test_drainPendingDropsQueuedItems() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "first"))
        q.enqueue(.init(text: "second"))
        q.enqueue(.init(text: "third"))
        // Consumer pulled "first" — it's "currently playing". Then a
        // drainPending should drop second and third.
        let first = await q.next()
        XCTAssertEqual(first?.text, "first")

        q.drainPending()
        XCTAssertEqual(q.queueDepth, 0)

        let next = await q.next()
        XCTAssertNil(next, "drainPending sealed the queue — no more items")
    }

    // MARK: - stop() — immediate cancel, synchronous

    func test_stopIsSynchronousAndImmediate() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "one", language: "en-US"))
        q.enqueue(.init(text: "two"))
        _ = await q.next()
        XCTAssertTrue(q.isSpeaking)

        q.stop()
        // No await between stop() and these reads — the cancellation
        // contract requires sync state updates.
        XCTAssertFalse(q.isSpeaking, "stop() must clear isSpeaking synchronously")
        XCTAssertEqual(q.queueDepth, 0)
        XCTAssertNil(q.currentLanguage)

        let item = await q.next()
        XCTAssertNil(item, "After stop, next() returns nil even if items were pending")
    }

    func test_stopUnblocksAwaitingConsumer() async {
        let q = AudioQueue()

        // Consumer suspends on next() before any enqueue.
        async let waiting = q.next()

        // Give the suspension a moment to engage.
        try? await Task.sleep(nanoseconds: 50_000_000)
        q.stop()
        let result = await waiting
        XCTAssertNil(result, "stop() must wake a suspended consumer with nil")
    }

    func test_enqueueAfterStopIsDropped() async {
        let q = AudioQueue()
        q.stop()
        q.enqueue(.init(text: "shouldnt show"))
        let item = await q.next()
        XCTAssertNil(item)
    }

    // MARK: - finish() vs drainPending() interaction

    func test_finishUnblocksAwaitingConsumerWhenQueueEmpty() async {
        let q = AudioQueue()
        async let waiting = q.next()
        try? await Task.sleep(nanoseconds: 50_000_000)
        q.finish()
        let result = await waiting
        XCTAssertNil(result, "finish() with empty queue wakes consumer with nil")
    }

    func test_finishDoesNotDropPending() async {
        let q = AudioQueue()
        q.enqueue(.init(text: "queued"))
        q.finish()
        let item = await q.next()
        XCTAssertEqual(item?.text, "queued")
    }
}

// MARK: - Apple system speech route regression

@MainActor
final class SystemSpeechPCMTests: XCTestCase {
    func test_appleSystemVoiceRendersNonEmptyPCM() async throws {
        let service = SystemSpeechService()
        guard let voice = service.defaultVoice else {
            throw XCTSkip("This simulator has no installed Apple speech voice.")
        }

        let result = try await service.synthesize(
            text: "IOSLocalLLM audio route check.",
            voice: voice,
            settings: VoiceSynthesisSettings()
        )

        XCTAssertEqual(result.engineKind, .appleSystem)
        XCTAssertTrue(result.requiresExternalPlayback)
        XCTAssertGreaterThan(result.sampleRate, 0)
        XCTAssertGreaterThan(result.duration, 0)
        XCTAssertGreaterThan(result.pcmBuffer?.frameLength ?? 0, 0)
    }

    /// iOS 17+ lists the novelty (Albert, Zarvox, …) and Eloquence (Eddy,
    /// Flo, …) voices in speechVoices(). They are robotic by design and must
    /// never be offered or auto-picked — the "synthetic robotic voice for
    /// everything" bug was Albert winning the alphabetical tie-break.
    func test_roboticSynthVoicesNeverOffered() async {
        let service = SystemSpeechService()
        await service.refreshVoices()
        XCTAssertFalse(service.availableVoices.isEmpty)
        for v in service.availableVoices {
            let id = v.id.lowercased()
            XCTAssertFalse(id.contains("eloquence"), "Eloquence voice offered: \(v.id)")
            XCTAssertFalse(id.contains(".speech.synthesis.voice"), "Legacy MacinTalk voice offered: \(v.id)")
        }
        if let def = service.defaultVoice {
            let raw = def.id.replacingOccurrences(of: "system:", with: "")
            if let av = AVSpeechSynthesisVoice(identifier: raw) {
                XCTAssertFalse(SystemSpeechService.isRoboticSynth(av),
                               "Default voice is a robotic synth: \(def.id)")
            }
        }
    }
}

@MainActor
final class OnnxTTSEngineTests: XCTestCase {

    func test_supertonicPreprocessMatchesReference() {
        XCTAssertEqual(SupertonicTTSService.preprocess("Hello — world", lang: "en"), "<en>Hello - world.</en>")
        XCTAssertEqual(SupertonicTTSService.preprocess("Merhaba 😀  dünya!", lang: "tr"),
                       "<tr>Merhaba du\u{0308}nya!</tr>")
    }

    func test_supertonicLanguageAndChunks() {
        XCTAssertEqual(SupertonicTTSService.language(for: "Bugün hava çok güzel, dışarı çıkalım mı?"), "tr")
        let chunks = SupertonicTTSService.chunks(String(repeating: "One short sentence here. ", count: 40), maxLength: 300)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 300 })
    }

    /// Downloads the pinned models into the test host and speaks with both
    /// engines. Opt-in: `TEST_RUNNER_ONNX_TTS_E2E=1 xcodebuild test …`.
    func test_enginesSpeakEndToEnd() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ONNX_TTS_E2E"] == "1")
        try await fetch("sahilmahendrakar/Paradee-8M-v1.2", "ed2934d4df8a4fd891e29584c5e1104649409765",
                        ["onnx/paradee_int8.onnx", "config.json"], into: ParadeeTTSService.directory)
        try await fetch("Supertone/supertonic-3", "3cadd1ee6394adea1bd021217a0e650ede09a323",
                        ["onnx/duration_predictor.onnx", "onnx/text_encoder.onnx", "onnx/vector_estimator.onnx",
                         "onnx/vocoder.onnx", "onnx/tts.json", "onnx/unicode_indexer.json",
                         "voice_styles/F1.json", "voice_styles/M1.json"], into: SupertonicTTSService.directory)

        let paradee = ParadeeTTSService()
        await paradee.load()
        XCTAssertEqual(paradee.modelState, .ready)
        let english = try await paradee.synthesize(text: Self.englishProbe,
                                                   voice: ParadeeTTSService.paradeeVoices[0], settings: .init())
        XCTAssertGreaterThan(english.duration, 1.0)

        let supertonic = SupertonicTTSService()
        await supertonic.load()
        XCTAssertEqual(supertonic.modelState, .ready)
        let turkish = try await supertonic.synthesize(text: "Merhaba, bugün hava çok güzel.",
                                                      voice: SupertonicTTSService.supertonicVoices[0], settings: .init())
        XCTAssertGreaterThan(turkish.duration, 1.0)
        XCTAssertEqual(turkish.sampleRate, 44_100)

        // Kokoro shares KokoroPhonemizer with Paradee.
        try await fetchTree("aufklarer/Kokoro-82M-CoreML", "f8ff771e4cab0bb3368e8af3a090a7e847485401",
                            prefixes: ["kokoro_5s.mlmodelc/", "G2PEncoder.mlmodelc/", "G2PDecoder.mlmodelc/",
                                       "voices/af_heart.json", "config.json", "pipeline_config.json",
                                       "g2p_vocab.json", "vocab_index.json"],
                            into: VoiceModelBundleValidator.voiceModelsRoot().appendingPathComponent("Kokoro"))
        let kokoro = KokoroTTSService()
        await kokoro.load()
        XCTAssertEqual(kokoro.modelState, .ready)
        let kokoroVoice = try XCTUnwrap(KokoroTTSService.kokoroVoices.first { $0.id.hasSuffix("af_heart") })
        let kokoroEnglish = try await kokoro.synthesize(text: Self.englishProbe, voice: kokoroVoice, settings: .init())
        XCTAssertGreaterThan(kokoroEnglish.duration, 1.0)

        // Optional listening copies: TEST_RUNNER_ONNX_TTS_WAV_DIR=/some/dir
        if let dir = ProcessInfo.processInfo.environment["ONNX_TTS_WAV_DIR"] {
            for (name, result) in [("paradee-en", english), ("supertonic-tr", turkish), ("kokoro-en", kokoroEnglish)] {
                guard let buffer = result.pcmBuffer else { continue }
                let file = try AVAudioFile(forWriting: URL(fileURLWithPath: dir).appendingPathComponent("\(name).wav"),
                                           settings: buffer.format.settings)
                try file.write(from: buffer)
            }
        }
    }

    /// Diphthongs (tiny, voice, cold, now, day) and r-coloured vowels (her, bird, water).
    private static let englishProbe = "Hello from Paradee, the tiny voice. Her bird likes cold water today, right now."

    private func fetchTree(_ repo: String, _ revision: String, prefixes: [String], into dir: URL) async throws {
        let api = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=true")!
        let (data, _) = try await URLSession.shared.data(from: api)
        let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let files = entries.compactMap { $0["type"] as? String == "file" ? $0["path"] as? String : nil }
            .filter { path in prefixes.contains { path == $0 || path.hasPrefix($0) } }
        try await fetch(repo, revision, files, into: dir)
    }

    private func fetch(_ repo: String, _ revision: String, _ files: [String], into dir: URL) async throws {
        for file in files {
            let target = dir.appendingPathComponent(file)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")!
            let (temp, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: target)
        }
    }
}
