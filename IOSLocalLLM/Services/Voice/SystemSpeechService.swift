import AVFoundation
import Foundation

// MARK: - SystemSpeechService
// Wraps AVSpeechSynthesizer for always-available TTS. Speech is rendered to
// PCM with `write(_:toBufferCallback:)` and played by AudioPlaybackService;
// we deliberately do not use AVSpeechSynthesizer's private playback audio
// unit, which can remain attached to a stale playAndRecord/HFP route.
// No model download required. Supports all iOS voices.

@MainActor
final class SystemSpeechService: NSObject, LocalVoiceEngine, ObservableObject {

    // MARK: - LocalVoiceEngine

    let kind: VoiceEngineKind = .appleSystem
    private(set) var modelState: VoiceModelState = .ready  // always ready

    var isReady: Bool { true }

    // MARK: - Available voices

    /// True for voices that are robotic BY DESIGN and must never be
    /// auto-selected: iOS 17+ ships the macOS novelty voices (Albert, Bells,
    /// Zarvox, …) and the Eloquence screen-reader voices (Eddy, Flo, Grandma,
    /// …) in `speechVoices()`, all at `.default` quality. The old alphabetical
    /// tie-break made "Albert" the English default on any device with no
    /// Enhanced/Premium voice downloaded — the unfixable-looking "synthetic
    /// robotic voice for everything" report. Personal Voices are excluded too:
    /// without authorization they render silence.
    static func isRoboticSynth(_ voice: AVSpeechSynthesisVoice) -> Bool {
        if voice.voiceTraits.contains(.isNoveltyVoice) { return true }
        if voice.voiceTraits.contains(.isPersonalVoice) { return true }
        let id = voice.identifier.lowercased()
        return id.contains("eloquence")                  // Eddy/Flo/Grandma/…
            || id.contains(".speech.synthesis.voice")    // legacy MacinTalk (Fred, …)
    }

    /// Every system voice worth offering — novelty/Eloquence/personal filtered.
    private var usableAVVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { !Self.isRoboticSynth($0) }
    }

    var availableVoices: [VoiceOption] {
        // Keep the device language ahead of every foreign language, then rank
        // quality within a language. A previous version put every English
        // voice ahead of the device language. On a Turkish (or any non-English)
        // phone that silently selected an English Premium voice for local text;
        // the result sounds far worse than a compact same-language voice and
        // was reported as the Apple "zombie" voice.
        let deviceLang = Locale.current.language.languageCode?.identifier ?? "en"
        // Within a language+quality bucket, the system's own pick for the
        // language (e.g. Samantha for en-US) beats alphabetical order.
        let systemPickID = AVSpeechSynthesisVoice(
            language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
        let avVoices = usableAVVoices
            .sorted { a, b in
                let aScore = qualityScore(a)
                let bScore = qualityScore(b)
                let aIsEn = a.language.hasPrefix("en")
                let bIsEn = b.language.hasPrefix("en")
                let aIsDevice = a.language.hasPrefix(deviceLang)
                let bIsDevice = b.language.hasPrefix(deviceLang)

                if aIsDevice != bIsDevice { return aIsDevice }
                let aLanguage = a.language.split(separator: "-").first ?? ""
                let bLanguage = b.language.split(separator: "-").first ?? ""
                if aLanguage == bLanguage, aScore != bScore { return aScore > bScore }
                // English is the broad fallback only after the device language.
                if aIsEn != bIsEn { return aIsEn }
                if aScore != bScore { return aScore > bScore }
                if let systemPickID, (a.identifier == systemPickID) != (b.identifier == systemPickID) {
                    return a.identifier == systemPickID
                }
                return a.name < b.name
            }

        return avVoices.map { av in
            VoiceOption(
                id: "system:\(av.identifier)",
                name: av.name,
                engineKind: .appleSystem,
                locale: av.language,
                description: qualityLabel(av)
            )
        }
    }

    /// Best available voice. Language correctness wins over asset quality:
    /// a compact voice in the user's language is preferable to a Premium
    /// English voice pronouncing that language as English.
    var defaultVoice: VoiceOption? {
        let voices = availableVoices
        let deviceLang = Locale.current.language.languageCode?.identifier ?? "en"
        if let match = voices.first(where: {
            isHighQuality($0) && $0.locale.hasPrefix(deviceLang)
        }) {
            return match
        }
        if let sameLanguage = voices.first(where: { $0.locale.hasPrefix(deviceLang) }) {
            return sameLanguage
        }
        if let premiumEnglish = voices.first(where: {
            isHighQuality($0) && $0.locale.hasPrefix("en")
        }) {
            return premiumEnglish
        }
        if let anyHQ = voices.first(where: { isHighQuality($0) }) {
            return anyHQ
        }
        return voices.first
    }

    /// Compact "Default" AVSpeech voices are the thin robotic/zombie
    /// ones. If the caller hands us one of those and a Premium/Enhanced
    /// voice exists for the same language, swap it. Also used to migrate
    /// a persisted `voiceID` that still points at a Default voice from
    /// an older build.
    func upgradedVoice(for voice: VoiceOption) -> VoiceOption {
        guard voice.engineKind == .appleSystem else { return voice }
        guard !isHighQuality(voice) else { return voice }
        let langPrefix = voice.locale.split(separator: "-").first.map(String.init)
            ?? voice.locale
        if let better = availableVoices.first(where: {
            isHighQuality($0)
                && ($0.locale.split(separator: "-").first.map(String.init) ?? $0.locale)
                    .caseInsensitiveCompare(langPrefix) == .orderedSame
        }) {
            return better
        }
        // Never "upgrade" across languages. Correct phonemes matter more than
        // the Premium/Enhanced badge; the per-chunk router can still choose a
        // better same-language voice when one is installed later.
        return voice
    }

    func isHighQuality(_ voice: VoiceOption) -> Bool {
        let label = voice.description?.lowercased() ?? ""
        return label.contains("premium") || label.contains("enhanced")
    }

    // MARK: - Private state

    private let synthesizer = AVSpeechSynthesizer()
    private var activeRenderRequest: AppleSpeechRenderRequest?

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - LocalVoiceEngine — load / unload (no-op)

    func load() async { /* AVSpeechSynthesizer needs no loading */ }
    func unload() {
        activeRenderRequest?.cancel()
        activeRenderRequest = nil
        // Main-thread only (see stop()).
        if Thread.isMainThread {
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    // MARK: - Synthesize

    func synthesize(
        text: String,
        voice: VoiceOption,
        settings: VoiceSynthesisSettings
    ) async throws -> VoiceSynthesisResult {
        // Derive AVSpeechSynthesisVoice from the VoiceOption identifier
        let avIdentifier = voice.id.hasPrefix("system:")
            ? String(voice.id.dropFirst("system:".count))
            : voice.id
        // Three-tier fallback so we never hand AVSpeechSynthesizer a nil
        // voice — when `voice` is nil iOS sometimes uses the default,
        // sometimes silently drops the utterance (most reliably on iOS
        // 18+ when the session was reconfigured after the synthesizer was
        // created). The last fallback uses the current language code,
        // which is always backed by a system voice on every iOS device.
        // Resolve, then refuse a compact Default when a better voice for
        // the same language is installed. Handing AVSpeech a Default
        // voice is the most common "zombie / synthetic" complaint even
        // with a clean audio session.
        var avVoice = AVSpeechSynthesisVoice(identifier: avIdentifier)
            ?? AVSpeechSynthesisVoice(language: voice.locale)
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            ?? AVSpeechSynthesisVoice(language: "en-US")
        if let resolved = avVoice,
           resolved.quality == .default || Self.isRoboticSynth(resolved) {
            let langPrefix = String(resolved.language.prefix(2))
            let candidates = usableAVVoices
                .filter { $0.language.hasPrefix(langPrefix) }
                .sorted { qualityScore($0) > qualityScore($1) }
            // Prefer Enhanced/Premium; a robotic resolve (persisted novelty /
            // Eloquence ID from an older build) is replaced even by a compact
            // normal voice — Samantha beats Zarvox.
            if let better = candidates.first(where: { $0.quality != .default })
                ?? (Self.isRoboticSynth(resolved) ? candidates.first : nil) {
                avVoice = better
            }
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice  = avVoice
        utterance.rate   = AVSpeechUtteranceDefaultSpeechRate * settings.speed
        utterance.pitchMultiplier = settings.pitch
        // Volume of 0 silently drops the utterance — guard against the
        // case where AppSettings.voiceVolume got clobbered to 0 by an
        // accidental drag, so the user always hears *something* and can
        // confirm TTS is wired correctly. Floor at 0.05; if the user
        // really wants silence they can flip the voice-answer toggle off.
        utterance.volume = max(0.05, settings.volume)
        utterance.preUtteranceDelay  = 0
        utterance.postUtteranceDelay = 0

        // Render offline instead of calling `speak`. AVSpeechSynthesizer's
        // private output audio unit can survive a record→playback category
        // change and keep using the narrow full-duplex route (the persistent
        // "zombie" sound). PCM rendering uses Apple's exact same voice model,
        // rate, and pitch but lets IOSLocalLLM own the one output engine/route.
        let request = AppleSpeechRenderRequest()
        activeRenderRequest?.cancel()
        activeRenderRequest = request
        defer {
            if activeRenderRequest === request { activeRenderRequest = nil }
        }

        let pcm = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                if synthesizer.isSpeaking {
                    synthesizer.stopSpeaking(at: .immediate)
                }
                synthesizer.write(utterance) { buffer in
                    request.consume(buffer)
                }
            }
        } onCancel: {
            request.cancel()
            Task { @MainActor [weak self] in
                self?.synthesizer.stopSpeaking(at: .immediate)
            }
        }

        let duration = pcm.format.sampleRate > 0
            ? Double(pcm.frameLength) / pcm.format.sampleRate
            : 0
        let renderedVoiceName = avVoice?.name ?? voice.name
        let renderedVoiceQuality = avVoice.map(qualityLabel) ?? "Unknown"
        let renderedDuration = String(format: "%.2f", duration)
        Diagnostics.shared.notice(
            "Apple TTS PCM ready · \(renderedVoiceName) · \(renderedVoiceQuality) · \(Int(pcm.format.sampleRate)) Hz · \(renderedDuration)s",
            category: "voice"
        )

        return VoiceSynthesisResult(
            pcmBuffer: pcm,
            sampleRate: pcm.format.sampleRate,
            duration: duration,
            engineKind: .appleSystem,
            voiceID: avVoice?.identifier ?? voice.id,
            alignment: nil,
            synthesisMetadata: SynthesisMetadata(
                sourceText: text,
                engineKind: .appleSystem
            )
        )
    }

    // MARK: - Stop

    func stop() {
        activeRenderRequest?.cancel()
        activeRenderRequest = nil
        // AVSpeechSynthesizer must be driven on the main thread — off-thread
        // use SIGSEGVs in TextToSpeech's BufferAllocator.
        if Thread.isMainThread {
            synthesizer.stopSpeaking(at: .immediate)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    // MARK: - Helpers

    private func qualityScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium:  return 3
        case .enhanced: return 2
        default:        return 1
        }
    }

    private func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Default"
        }
    }
}

// MARK: - Apple speech PCM render

/// Thread-safe bridge from AVSpeechSynthesizer's buffer callback to one PCM
/// result. Buffers supplied to the callback are transient, so they are written
/// to a short-lived CAF and read back once the terminal zero-length buffer
/// arrives. This avoids assumptions about Apple's output sample format while
/// keeping memory bounded for long replies.
private final class AppleSpeechRenderRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ioslocalllm-apple-tts-\(UUID().uuidString).caf")
    private var continuation: CheckedContinuation<AVAudioPCMBuffer, Error>?
    private var writer: AVAudioFile?
    private var resolved = false

    func install(_ continuation: CheckedContinuation<AVAudioPCMBuffer, Error>) {
        lock.lock()
        if resolved {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func consume(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            fail(AppleSpeechRenderError.invalidBuffer)
            return
        }
        let byteCount = pcm.audioBufferList.pointee.mBuffers.mDataByteSize
        if pcm.frameLength == 0 || byteCount == 0 {
            finish()
            return
        }

        lock.lock()
        guard !resolved else { lock.unlock(); return }
        do {
            if writer == nil {
                writer = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
            }
            try writer?.write(from: pcm)
            lock.unlock()
        } catch {
            let continuation = resolveLocked()
            lock.unlock()
            try? FileManager.default.removeItem(at: url)
            continuation?.resume(throwing: error)
        }
    }

    func cancel() {
        lock.lock()
        let continuation = resolveLocked()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
        continuation?.resume(throwing: CancellationError())
    }

    private func finish() {
        lock.lock()
        guard !resolved else { lock.unlock(); return }
        let continuation = resolveLocked()
        lock.unlock()

        do {
            let reader = try AVAudioFile(forReading: url)
            guard reader.length > 0,
                  reader.length <= AVAudioFramePosition(UInt32.max),
                  let output = AVAudioPCMBuffer(
                    pcmFormat: reader.processingFormat,
                    frameCapacity: AVAudioFrameCount(reader.length)
                  ) else {
                throw AppleSpeechRenderError.emptyAudio
            }
            try reader.read(into: output)
            try? FileManager.default.removeItem(at: url)
            continuation?.resume(returning: output)
        } catch {
            try? FileManager.default.removeItem(at: url)
            continuation?.resume(throwing: error)
        }
    }

    private func fail(_ error: Error) {
        lock.lock()
        let continuation = resolveLocked()
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
        continuation?.resume(throwing: error)
    }

    /// Caller holds `lock`.
    private func resolveLocked() -> CheckedContinuation<AVAudioPCMBuffer, Error>? {
        guard !resolved else { return nil }
        resolved = true
        writer = nil       // close/flush the CAF before the reader opens it
        let continuation = continuation
        self.continuation = nil
        return continuation
    }
}

private enum AppleSpeechRenderError: LocalizedError {
    case invalidBuffer
    case emptyAudio

    var errorDescription: String? {
        switch self {
        case .invalidBuffer: return "Apple speech returned an unsupported audio buffer."
        case .emptyAudio: return "Apple speech produced no audio."
        }
    }
}
