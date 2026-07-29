import AVFoundation
import Speech
import Combine

// MARK: - SpeechDictationService
// Wraps SFSpeechRecognizer + AVAudioEngine. Two operating modes:
//
//   Single-shot (chat composer):
//     start { transcript, isFinal in … }   // default continuous = false
//     The recognizer's first `isFinal` tears the audio graph down and
//     deactivates the shared AVAudioSession.
//
//   Continuous (voice-conversation):
//     start(continuous: true) { transcript, _ in … }
//     The audio engine + tap stay alive across recognizer phrase boundaries.
//     Internally we just rotate to a fresh recognition request when the
//     recognizer declares isFinal, so background noise can no longer cause
//     a stop/restart cycle. The caller owns the audio session lifecycle —
//     SpeechDictationService.cleanup() does NOT setActive(false) in this
//     mode, letting the parent service keep `.playAndRecord` hot for the
//     TTS that comes next.
//
//   pauseRecognition() / resumeRecognition()
//     For continuous mode. Ends the current SFSpeechRecognizer request so
//     the mic stops transcribing (for example, while we're speaking to the
//     user via TTS — otherwise we'd transcribe our own output back into the
//     next user turn). The audio engine keeps running so level metering
//     remains available for the orb UI.

@MainActor
final class SpeechDictationService: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isRecording = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var levelMeter: Float = 0   // 0–1, for waveform UI
    @Published private(set) var lastError: String?

    // MARK: - Private

    private let recognizer = SpeechDictationService.makeRecognizer()

    /// Picks the best available SFSpeechRecognizer using a locale chain:
    ///
    ///   0. user-pinned locale (`AppSettings.sttLocaleOverride`)
    ///   1. exact device locale (e.g. `tr-TR`)
    ///   2. any region for the device's language (e.g. `tr_*` → first match)
    ///   3. `en-US` as the universal fallback
    ///   4. the first locale SFSpeechRecognizer actually supports
    ///
    /// At each step we additionally require `isAvailable == true`. Without
    /// the chain, a user on `tr-TR` whose recognizer briefly reports
    /// unavailable would silently fall back to `en-US` and start
    /// transcribing their Turkish as garbled English. With it, we try a
    /// neighbouring Turkish region before crossing the language line.
    private static func makeRecognizer() -> SFSpeechRecognizer? {
        let supported = SFSpeechRecognizer.supportedLocales()
        let deviceLocale = Locale.current
        let deviceLangCode = deviceLocale.language.languageCode?.identifier

        var candidates: [Locale] = []

        // User pin takes precedence over the device locale. Only honour
        // it when SFSpeechRecognizer can actually recognise the value;
        // an outdated saved identifier should fall through to the auto
        // chain rather than silently disabling dictation.
        let pinned = UserDefaults.standard.string(forKey: "sttLocaleOverride") ?? ""
        if !pinned.isEmpty {
            let pinLocale = Locale(identifier: pinned)
            if supported.contains(where: { $0.identifier == pinLocale.identifier })
                || SFSpeechRecognizer(locale: pinLocale) != nil {
                candidates.append(pinLocale)
            }
        }

        candidates.append(deviceLocale)

        // Same language, any region.
        if let lang = deviceLangCode {
            let sameLang = supported
                .filter { $0.language.languageCode?.identifier == lang }
                .filter { $0.identifier != deviceLocale.identifier }
            candidates.append(contentsOf: sameLang)
        }

        // Universal English fallback.
        candidates.append(Locale(identifier: "en-US"))

        // Last-ditch: anything the OS supports.
        candidates.append(contentsOf: supported)

        var seen = Set<String>()
        for locale in candidates where seen.insert(locale.identifier).inserted {
            if let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable {
                if locale.identifier != deviceLocale.identifier {
                    print("[SpeechDictation] Falling back from \(deviceLocale.identifier) to \(locale.identifier)")
                }
                return rec
            }
        }
        return nil
    }
    private let audioEngine = AVAudioEngine()

    /// Lock guarding the recognition request the audio tap feeds. The tap
    /// runs on a real-time render thread while the main actor swaps the
    /// request on every phrase rotation / pause / cleanup — and in
    /// continuous mode the tap is NOT removed across those swaps (the
    /// engine stays hot for level metering). Reading a class reference
    /// while it's being reassigned is a retain/release data race →
    /// intermittent EXC_BAD_ACCESS ("voice mode crashes sometimes").
    /// All access to `_request` goes through this lock so the tap always
    /// sees a safely-retained snapshot.
    private let requestLock = NSLock()
    private nonisolated(unsafe) var _request: SFSpeechAudioBufferRecognitionRequest?
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestLock.lock(); defer { requestLock.unlock() }; return _request }
        set { requestLock.lock(); _request = newValue; requestLock.unlock() }
    }

    /// Appends a captured buffer to the current request under the lock.
    /// `nonisolated` so the audio tap can call it directly without hopping
    /// to the main actor (which would add latency and drop buffers).
    /// Snapshotting under the lock holds a +1 on the request for the
    /// duration of `append`, so a concurrent `request = nil` on the main
    /// actor can't free it out from under us. `append(_:)` itself is
    /// documented safe to call from any thread.
    private nonisolated func appendToCurrentRequest(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock()
        let req = _request
        requestLock.unlock()
        req?.append(buffer)
    }

    private var task: SFSpeechRecognitionTask?
    private var onTranscript: ((String, Bool) -> Void)?
    /// When true: rotate recognition requests on `isFinal` instead of
    /// cleaning up; cleanup leaves the audio session active for the caller.
    private var continuous: Bool = false
    /// While true the audio tap drops incoming buffers on the floor. Used
    /// during TTS playback to keep the engine running (so level meter +
    /// VAD stay live) without feeding the assistant's own voice back into
    /// the recogniser.
    private var inputPaused: Bool = false
    /// Bumped on every pause / stop / new recognition request so a cancelled
    /// SFSpeechRecognitionTask's async completion cannot call `cleanup()` or
    /// rotate into a fresh request after we've intentionally paused for TTS.
    /// Without this, the first turn's endAudio/cancel tears the continuous
    /// session down (`isRecording = false`) and `resumeRecognition()` becomes
    /// a silent no-op — UI shows Listening but the mic never comes back.
    private var recognitionGeneration: UInt64 = 0

    /// When true (continuous / voice-conversation mode) the tap resamples each
    /// buffer to 16 kHz mono and accumulates it for the neural VAD. Kept hot
    /// even while `inputPaused` so barge-in can fire during TTS playback.
    private var captureVADFrames: Bool = false
    /// 16 kHz mono frames awaiting the VAD. Written from the audio render
    /// thread, drained by the listening loop on the main actor — lock-guarded
    /// for the same reason as `_request`.
    private let vadFrameLock = NSLock()
    private nonisolated(unsafe) var vadFrames: [Float] = []

    /// Resample one tap buffer to 16 kHz mono and append it for the VAD.
    /// `nonisolated` so it runs inline on the audio thread (same pattern as
    /// the Whisper single-shot tap). Bounded so a stalled drain can't grow
    /// it without limit.
    private nonisolated func captureFramesForVAD(_ buffer: AVAudioPCMBuffer) {
        guard let samples = WhisperContext.resampleTo16kMonoFloat(buffer),
              !samples.isEmpty else { return }
        vadFrameLock.lock()
        vadFrames.append(contentsOf: samples)
        let cap = 32_000   // ~2 s @ 16 kHz
        if vadFrames.count > cap { vadFrames.removeFirst(vadFrames.count - cap) }
        vadFrameLock.unlock()
    }

    /// Pulls and clears the 16 kHz frames captured since the last call.
    /// Returns empty when frame capture is off or nothing has arrived.
    func drainVADFrames() -> [Float] {
        vadFrameLock.lock(); defer { vadFrameLock.unlock() }
        let out = vadFrames
        vadFrames.removeAll(keepingCapacity: true)
        return out
    }

    deinit {
        // Stop engine + clear tap synchronously so we don't leak the audio
        // graph if the service is recreated.
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        requestLock.lock()
        _request?.endAudio()
        _request = nil
        requestLock.unlock()
    }

    // MARK: - Authorization

    /// Returns true if the user grants permission. Triggers the system prompt
    /// on first call. Subsequent calls return the cached state.
    func requestAuthorization() async -> Bool {
        // Speech recognition permission
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }

        // Microphone permission
        let micStatus: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }

        let ok = speechStatus == .authorized && micStatus
        isAuthorized = ok
        if !ok {
            lastError = speechStatus == .denied
                ? "Speech recognition permission denied. Enable in Settings."
                : "Microphone permission denied. Enable in Settings."
        }
        return ok
    }

    var isAvailable: Bool {
        recognizer?.isAvailable == true
    }

    // MARK: - Start / Stop

    /// Starts streaming partial transcripts to `onTranscript`. The callback
    /// receives the running transcript and a boolean `isFinal` flag.
    /// When `continuous` is true (voice-conversation mode), the audio engine
    /// stays running across SFSpeechRecognizer's internal phrase boundaries
    /// and the AVAudioSession is left active when the service is stopped —
    /// the caller owns that lifecycle so TTS can speak through the same
    /// session without re-activation hiccups.
    func start(continuous: Bool = false,
               _ onTranscript: @escaping (String, Bool) -> Void) throws {
        guard !isRecording else { return }

        // Provider routing. Whisper is only valid in single-shot mode —
        // it isn't a streaming model, so continuous-mode voice
        // conversations always fall through to SFSpeechRecognizer
        // regardless of the setting. The Whisper path also requires a
        // model on disk; missing model → fall back to system so the
        // user isn't silently broken if they enabled the toggle then
        // deleted the model.
        let wantsWhisper = AppSettings.shared.sttProvider == "whisper"
        if wantsWhisper, !continuous, WhisperModelCatalog.isInstalled {
            try startWhisperSingleShot(onTranscript)
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechDictation", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Speech recognition isn't available right now."
            ])
        }

        self.onTranscript = onTranscript
        self.continuous = continuous
        self.inputPaused = false
        // Feed the neural VAD only in conversation mode. Cleared in cleanup().
        self.captureVADFrames = continuous
        vadFrameLock.lock(); vadFrames.removeAll(keepingCapacity: true); vadFrameLock.unlock()
        lastError = nil

        let session = AVAudioSession.sharedInstance()
        if continuous {
            // Conversation mode: caller (VoiceConversationService) has
            // already set the session to .playAndRecord so TTS can come
            // through the same route. We just make sure it's active.
            try? session.setActive(true, options: [])
        } else {
            // Single-shot dictation — record-only is fine and gives us the
            // measurement mode which is tuned for mic-up-close speech.
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }

        // Tap audio engine — installed once and left in place across
        // recognition-request rotations. The tap closure appends to whatever
        // `request` is currently set, so swapping the request mid-stream
        // doesn't lose any audio.
        let inputNode = audioEngine.inputNode

        // Voice processing (echo cancellation, noise suppression, AGC) is
        // the industry-standard barge-in enabler: without it, the mic
        // picks up the assistant's own TTS through the loudspeaker and
        // re-transcribes it. AVAudioInputNode flips this on with a
        // single call (iOS 13+). It's a no-op outside of continuous
        // conversation mode — single-shot dictation already runs against
        // a quiet room.
        //
        // The user-facing toggle (`AppSettings.voiceProcessingEnabled`)
        // is a safety valve: on a handful of audio routes, voice
        // processing has been observed to interact with `.spokenAudio`
        // mode and produce distorted TTS. If a user reports residual
        // garble after the session-idempotency fix, they can disable
        // this in Voice settings and confirm the diagnosis.
        if continuous && AppSettings.shared.voiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                // Older devices / certain audio routes refuse voice
                // processing. Barge-in becomes less reliable but the
                // rest of the conversation flow still works.
                print("[SpeechDictation] voice processing unavailable: \(error)")
            }
        }

        // Defensive format query. On first launch right after the user
        // grants microphone permission, the AVAudioSession can still be
        // settling and `outputFormat(forBus: 0)` returns a 0 Hz / 0-channel
        // "no input route" sentinel — sometimes accompanied by an earlier
        // `IPCAUClient: can't connect to server (-66748)` in the log.
        // Installing a tap with that format trips
        // `IsFormatSampleRateAndChannelCountValid` and converts to an
        // uncatchable Obj-C exception that terminates the app. Validate
        // here and throw a Swift error so the caller can transition to a
        // recoverable failed state and let the user retry.
        // Readiness guard only (throws on the transient 0 Hz / 0-channel
        // format). We do NOT pass this format to installTap: after
        // setVoiceProcessingEnabled(true), or on an 8 kHz Bluetooth HFP route,
        // passing an explicit format trips AVAudioEngine's "Failed to create
        // tap due to format mismatch" Obj-C exception and kills the app. Pass
        // nil so the tap uses the node's actual running format — SFSpeech and
        // the RMS meter accept any Float32 mono buffer.
        _ = try validInputFormat(inputNode, label: "system dictation")
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Compute RMS even when paused — caller relies on the level
            // meter for VAD calibration and orb animation.
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameCount { sum += channelData[i] * channelData[i] }
                let rms = sqrt(sum / Float(max(frameCount, 1)))
                let normalised = min(1.0, max(0.0, rms * 8))
                Task { @MainActor [weak self] in self?.levelMeter = normalised }
            }
            // Feed the neural VAD regardless of pause state — barge-in has to
            // keep detecting the user's voice while the assistant is speaking.
            if self.captureVADFrames { self.captureFramesForVAD(buffer) }
            // Drop audio into the recogniser only when not paused.
            guard !self.inputPaused else { return }
            self.appendToCurrentRequest(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        // Spin up the first recognition request. In continuous mode every
        // `isFinal` rotates instead of tearing down.
        startRecognitionRequest()

        isRecording = true
        HapticManager.impact(.medium)
    }

    /// Installs a fresh SFSpeechAudioBufferRecognitionRequest + recognitionTask
    /// and points `self.request` at it.
    private func startRecognitionRequest() {
        guard let recognizer else { return }
        // Invalidate in-flight completions before tearing down any prior task
        // so their cancel/isFinal handlers can't cleanup() or double-rotate.
        recognitionGeneration &+= 1
        let generation = recognitionGeneration
        // Defensive teardown: if a request/task already exists (e.g. a resume
        // raced an in-flight completion during barge-in, or two
        // return-to-listening paths both fired), end and cancel it before
        // creating a new one. Overwriting `request`/`task` without this orphans
        // a live SFSpeechRecognitionTask that keeps consuming the audio tap and
        // delivering stale partials into `onTranscript` — a "hears itself" /
        // battery-drain leak.
        if request != nil || task != nil {
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true   // privacy-first
        }
        request = req

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Stale callback from a paused/rotated/stopped request.
                guard generation == self.recognitionGeneration else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.onTranscript?(text, result.isFinal)
                }
                let finished = (error != nil) || (result?.isFinal ?? false)
                guard finished else { return }
                // Intentional pause for thinking/TTS — do not cleanup or rotate.
                // resumeRecognition() owns the next request.
                if self.inputPaused { return }
                guard self.isRecording else { return }
                if self.continuous {
                    if error == nil {
                        // Phrase boundary — keep the mic open and rotate.
                        self.rotateRecognitionRequest()
                    } else {
                        // Transient recognizer failure must not kill the
                        // conversation loop (that was the "listening but dead
                        // mic after first reply" path when cancel → cleanup).
                        self.startRecognitionRequest()
                    }
                } else {
                    self.cleanup()
                }
            }
        }
    }

    private func rotateRecognitionRequest() {
        // startRecognitionRequest bumps recognitionGeneration and cancels the
        // prior task; no need to end/cancel here (avoids a double-cancel race).
        startRecognitionRequest()
    }

    func stop() {
        guard isRecording else { return }
        HapticManager.impact(.light)
        // Whisper path: finalize routes the accumulated buffer through
        // WhisperContext.transcribe + fires the transcript callback,
        // and also tears down the audio graph itself. SFSpeechRecognizer
        // path: invalidate callbacks, end the request, tear down locally
        // (do not wait for isFinal — that used to race into cleanup twice).
        recognitionGeneration &+= 1
        if whisperBuffer != nil {
            finalizeWhisperSession()
        } else {
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
            cleanup()
        }
    }

    /// Continuous mode only. Ends the current recognition request without
    /// stopping the audio engine. The mic stays hot for level metering /
    /// VAD; the recogniser just stops transcribing until resume.
    func pauseRecognition() {
        guard continuous, isRecording else { return }
        inputPaused = true
        invalidateRecognitionTask()
    }

    /// Stop the mic graph for TTS. Leaving `AVAudioEngine` running under
    /// `.playAndRecord` forces AVSpeech through a full-duplex path that
    /// sounds thin/synthetic ("zombie") even on the built-in speaker.
    /// Recognition is already paused; this also tears down the input tap
    /// so the session can safely flip to `.playback`.
    func pauseEngineForTTS() {
        guard continuous, isRecording else { return }
        inputPaused = true
        invalidateRecognitionTask()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
        levelMeter = 0
        captureVADFrames = false
        vadFrameLock.lock(); vadFrames.removeAll(keepingCapacity: true); vadFrameLock.unlock()
    }

    /// Ends the active recognition task and bumps `recognitionGeneration` so
    /// its completion handler is a no-op. Shared by pause paths.
    private func invalidateRecognitionTask() {
        recognitionGeneration &+= 1
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    /// Continuous mode only. Starts a fresh recognition request and lets the
    /// audio tap feed it again.
    /// - Returns: `false` when the continuous session is gone or the engine
    ///   could not be restarted (caller should surface a failed phase).
    @discardableResult
    func resumeRecognition() -> Bool {
        guard continuous, isRecording else {
            lastError = "Couldn't resume listening after speech playback."
            return false
        }
        inputPaused = false
        captureVADFrames = continuous
        // After TTS we may have stopped the engine entirely (pauseEngineForTTS).
        // After a route change it may also be dead. Rebuild the tap + start
        // before opening a new recognition request.
        if !audioEngine.isRunning {
            do {
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                try reinstallInputTap()
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                lastError = "Couldn't resume listening after an audio interruption."
                ToastCenter.shared.error("Microphone unavailable",
                                          detail: "Tap End and re-enter voice mode to retry.")
                return false
            }
        }
        startRecognitionRequest()
        return true
    }

    /// Re-install the continuous-mode input tap after `pauseEngineForTTS`
    /// removed it. Mirrors the tap setup in `start(continuous:)` without
    /// re-running session category / permission work.
    private func reinstallInputTap() throws {
        let inputNode = audioEngine.inputNode
        if continuous && AppSettings.shared.voiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                print("[SpeechDictation] voice processing unavailable on resume: \(error)")
            }
        }
        _ = try validInputFormat(inputNode, label: "system dictation resume")
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameCount { sum += channelData[i] * channelData[i] }
                let rms = sqrt(sum / Float(max(frameCount, 1)))
                let normalised = min(1.0, max(0.0, rms * 8))
                Task { @MainActor [weak self] in self?.levelMeter = normalised }
            }
            if self.captureVADFrames { self.captureFramesForVAD(buffer) }
            guard !self.inputPaused else { return }
            self.appendToCurrentRequest(buffer)
        }
        captureVADFrames = continuous
    }

    private func cleanup() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        // Reset voice processing so the next single-shot dictation
        // session starts from a clean input node (the setting persists
        // on AVAudioEngine across stops otherwise).
        try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        levelMeter = 0
        inputPaused = false
        captureVADFrames = false
        vadFrameLock.lock(); vadFrames.removeAll(keepingCapacity: true); vadFrameLock.unlock()
        // Continuous mode: the VoiceConversationService owns the session.
        // It needs to stay active so the very next TTS utterance plays
        // immediately. Deactivating here was the root cause of "voice mode
        // STT works but the assistant never speaks back".
        let wasContinuous = continuous
        continuous = false
        guard !wasContinuous else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Returns the input node's current format only if it's actually usable.
    /// Throws otherwise so the caller can show a recoverable error instead of
    /// hitting AVAudioEngine's hard assertion on `installTap`.
    ///
    /// The "0 Hz / 0 channels" case happens transiently when the audio
    /// session was activated a moment ago but the RemoteIO audio unit
    /// hasn't bound to the hardware route yet — most commonly right after
    /// the user grants microphone permission for the first time, or after
    /// `setVoiceProcessingEnabled(true)` reconfigures the input node.
    private func validInputFormat(_ inputNode: AVAudioInputNode,
                                  label: String) throws -> AVAudioFormat {
        let format = inputNode.outputFormat(forBus: 0)
        if format.sampleRate > 0 && format.channelCount > 0 { return format }
        // Last-ditch: ask for the hardware-side format instead of the
        // post-processing output format. On most devices these are
        // identical, but on routes where the output side is degenerate
        // the input side sometimes still has the real hardware rate.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 { return hwFormat }
        print("[SpeechDictation] \(label) input format invalid: " +
              "out=\(format), in=\(hwFormat)")
        throw NSError(domain: "SpeechDictation", code: -2, userInfo: [
            NSLocalizedDescriptionKey:
                "Microphone isn't ready yet. Tap voice mode again in a moment."
        ])
    }

    // MARK: - Whisper single-shot path
    //
    // Parallel mic-capture flow that accumulates Float32 PCM buffers in
    // memory until the caller stops dictation, then ships the whole buffer
    // through whisper.cpp for transcription. Single-shot only — Whisper
    // isn't a streaming model, so the continuous voice-conversation flow
    // keeps using SFSpeechRecognizer (unchanged above).
    //
    // We deliberately reuse the EXISTING audio engine + tap and the same
    // level-meter calculation so the chat composer's waveform UI keeps
    // working with either provider. The only divergence is what we do
    // with the buffer: SFSpeechRecognizer streams it to the recogniser
    // request, whereas Whisper appends it to `whisperBuffer` and waits
    // for stop() to fire the transcription.

    /// Accumulated Float32 mono 16 kHz samples for the active Whisper
    /// dictation session. Nil outside an active session.
    private var whisperBuffer: [Float]?

    private func startWhisperSingleShot(_ onTranscript: @escaping (String, Bool) -> Void) throws {
        self.onTranscript = onTranscript
        self.continuous = false
        self.inputPaused = false
        self.whisperBuffer = []
        lastError = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        // Same defensive guard + nil-format tap as the SFSpeech path (see the
        // comment there). resampleTo16kMonoFloat handles whatever rate the
        // node delivers, so an 8 kHz HFP route degrades gracefully instead of
        // crashing.
        _ = try validInputFormat(inputNode, label: "whisper dictation")
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Same RMS → level meter math as the SFSpeech path so the
            // composer's waveform UI doesn't behave differently between
            // providers.
            if let channelData = buffer.floatChannelData?[0] {
                let frameCount = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frameCount { sum += channelData[i] * channelData[i] }
                let rms = sqrt(sum / Float(max(frameCount, 1)))
                let normalised = min(1.0, max(0.0, rms * 8))
                Task { @MainActor [weak self] in self?.levelMeter = normalised }
            }
            // Append resampled samples to the running buffer. Resampling
            // per-buffer (vs. once at the end) keeps memory bounded and
            // makes a long dictation degrade linearly rather than spiking
            // at stop time.
            guard let samples = WhisperContext.resampleTo16kMonoFloat(buffer) else { return }
            Task { @MainActor [weak self] in
                self?.whisperBuffer?.append(contentsOf: samples)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        HapticManager.impact(.medium)
    }

    /// Transcribe the accumulated buffer with Whisper. Called from
    /// stop() when the active provider is Whisper. Reads off the main
    /// actor (Whisper inference is heavy) and re-enters MainActor to
    /// fire the transcript callback.
    ///
    /// On failure the user sees a Toast explaining what went wrong
    /// instead of an empty transcript box that looks like the recogniser
    /// ignored them. The cached `WhisperRuntime.shared` keeps the
    /// 142 MB model resident across calls so the dictation tap-to-stop
    /// → text latency is dominated by inference, not model load.
    private func finalizeWhisperSession() {
        let buffer = whisperBuffer ?? []
        whisperBuffer = nil
        let callback = onTranscript
        guard !buffer.isEmpty else {
            cleanup()
            callback?("", true)
            return
        }
        guard let modelPath = WhisperModelCatalog.installedModelPath() else {
            cleanup()
            lastError = "No whisper model installed."
            ToastCenter.shared.error(
                "Whisper model missing",
                detail: "Download it in Voice settings, or switch STT back to System."
            )
            callback?("", true)
            return
        }
        // Tear down the audio graph BEFORE running inference. Whisper
        // transcription can take ~1-2 seconds on A17 Pro; we don't want
        // the mic indicator to keep showing during that window.
        cleanup()
        Task.detached(priority: .userInitiated) { [callback] in
            do {
                // Cached runtime — reuses a previously loaded context
                // for the same model file. First call after launch
                // pays the ~250 ms whisper_init cost; subsequent calls
                // skip it entirely.
                let ctx = try WhisperRuntime.shared.context(for: modelPath)
                let text = try ctx.transcribe(samples: buffer, language: "auto")
                await MainActor.run { callback?(text, true) }
            } catch {
                // Drop the cached context — if the failure was due to a
                // corrupt or partially-written model file, the next try
                // should reload from disk fresh.
                WhisperRuntime.shared.unload()
                let message: String
                if let werror = error as? WhisperError,
                   let described = werror.errorDescription {
                    message = described
                } else {
                    message = error.localizedDescription
                }
                print("[Whisper] transcription failed: \(error)")
                await MainActor.run {
                    ToastCenter.shared.error(
                        "Whisper transcription failed",
                        detail: message
                    )
                    callback?("", true)
                }
            }
        }
    }
}
