import Foundation
import Combine
import AVFoundation

// MARK: - VoiceConversationService
// Hands-free voice loop with an industry-standard VAD pipeline.
//
//   start ──▶ calibrating (500ms ambient sample)
//        ──▶ listening   (mic open, waiting)
//        ──▶ thinking    (silence after speech → LLM)
//        ──▶ speaking    (TTS reading the reply)
//        ──▶ listening   (back to wait)
//
// Design choices that fix the previous "doesn't reply with voice" and
// "restarts on every background sound" reports:
//
//   • Listening uses `.playAndRecord` so the headset mic works. Speaking
//     flips to `.playback` and stops the mic engine — leaving playAndRecord
//     + a live AVAudioEngine under TTS was the remaining "zombie /
//     synthetic" Apple voice path even after HFP was dropped (full-duplex
//     audio unit thins AVSpeech on speaker and Bluetooth). After TTS we
//     restore playAndRecord and restart the engine before listening again.
//
//   • SpeechDictationService runs in continuous mode (audio engine never
//     restarts on phrase boundaries) and supports pause/resume so the
//     recogniser shuts off during TTS playback — otherwise the assistant
//     transcribes its own voice into the next user turn.
//
//   • Voice activity detection is energy-based with an adaptive noise
//     floor calibrated over the first 500ms after start. Background TV /
//     fan noise no longer crosses the threshold; close-talker speech of
//     any volume does. End-of-turn fires only after we've actually heard
//     speech (peakDuringTurn > threshold) AND ≥1s of silence has elapsed.

@MainActor
final class VoiceConversationService: ObservableObject {

    static let shared = VoiceConversationService()

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        case failed(String)
    }

    // MARK: - Published

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var liveReply: String = ""
    /// Legacy mic level. Nothing in the UI reads this — the orb samples
    /// VoiceVisualLevelStore directly — so it is intentionally NOT updated
    /// in the VAD loop. Publishing it at VAD cadence invalidated the whole
    /// VoiceConversationView tree ~50×/s for zero consumers (orb jank).
    /// Batched live-reply staging. Tokens land here and publish at ~8 Hz so
    /// VoiceConversationView re-evaluates on bursts, not per token.
    private var liveReplyBuffer = ""
    private var liveReplyFlushTask: Task<Void, Never>?

    /// AudioQueue for the IN-FLIGHT (or just-finished) reply. A new
    /// instance is published at the start of each `streamReply()`;
    /// AudioQueue's terminal-after-stop semantics mean we can't
    /// reuse the same instance across turns. SwiftUI observers
    /// (`VoiceStatusPill`) re-subscribe automatically when the
    /// property changes. Idle initial value so the pill's
    /// `isSpeaking` binding starts false.
    @Published private(set) var currentAudioQueue: AudioQueue = AudioQueue()

    // MARK: - Services

    private let dictation = SpeechDictationService()
    private let voice = VoiceService.shared
    private let assistant = CodingAssistantService.shared

    // MARK: - State

    private var session: [ChatMessage] = []
    /// Chat-tab model id remembered at start() so stop() can put things back.
    private var savedChatModelID: String?
    /// Driving the VAD loop. One Task per conversation; cancelled in stop().
    private var vadTask: Task<Void, Never>?
    /// The in-flight reply (LLM generation + TTS). Launched fire-and-forget
    /// by handleEndOfTurn so the VAD loop keeps ticking during think+speak —
    /// that is what makes barge-in actually work. The old code `await`ed the
    /// reply inside the loop, which suspended the loop for the entire TTS
    /// playback and left the barge-in branch unreachable. Cancelled by
    /// interrupt() / stop().
    private var replyTask: Task<Void, Never>?
    /// Restores the chat model after voice mode stops. Stored so a rapid
    /// stop/start can cancel a stale restore before it races the new session.
    private var modelRestoreTask: Task<Void, Never>?
    /// Handles transcript-editor submissions before `replyTask` takes over.
    /// Stored so repeated taps cannot overlap end-of-turn preparation.
    private var editedTurnTask: Task<Void, Never>?
    /// Latest transcript from the recogniser, kept up-to-date by the callback.
    private var pendingTranscript: String = ""
    /// When `pendingTranscript` last actually changed. Drives the
    /// transcript-stability end-of-turn safety net: SFSpeechRecognizer is an
    /// independent signal from the energy/neural VAD, so once it has produced
    /// a non-empty transcript that stops changing, the user has finished
    /// talking even if the VAD is stuck reporting "speech" (the "hears me but
    /// never stops listening / never answers" bug). Reset to nil whenever we
    /// (re)enter listening or clear the transcript.
    private var lastTranscriptChangeAt: Date?
    /// How long the transcript must sit unchanged before the safety net ends
    /// the turn. Set above `TurnEndpointer.maxEndSilence` (1.6 s) so a working
    /// VAD still drives normal turn-taking; this only rescues a stuck one.
    private let transcriptStabilityEndOfTurn: TimeInterval = 2.0
    /// Audio-session observers (interruption, route change, media services
    /// reset). Installed on start(), torn down on stop(). Without these,
    /// a phone call / Siri / unplugged AirPods would silently kill the
    /// session and the user would be stuck looking at an unresponsive orb.
    private var sessionObservers: [NSObjectProtocol] = []
    /// Phase we were in when an interruption began — used to restore the
    /// state machine to the same point once iOS hands the session back.
    private var phaseBeforeInterruption: Phase?
    /// Continuous-dictation transcript sink. Kept so a hard resume after TTS
    /// can rebuild the recognition session when `resumeRecognition()` fails
    /// (the "Listening but dead mic after first reply" path).
    private var continuousTranscriptHandler: ((String, Bool) -> Void)?

    // MARK: - Listening cadence
    //
    // The turn-taking thresholds now live in `TurnEndpointer.Config` and the
    // adaptive noise-floor math in `EnergyVAD` (Services/Voice/Listening/).
    // All that's left here is how often we poll the mic meter — 50 Hz is
    // plenty for ~250 ms phrase boundaries.
    private let vadTickInterval: TimeInterval = 0.02

    private init() {}

    // MARK: - Live reply batching

    /// Coalesce token publishes: SwiftUI sees ~8 updates/sec instead of one
    /// per generated token. The TTS branch consumes its own stripped stream,
    /// so batching the UI mirror costs nothing.
    private func appendLiveReplyToken(_ token: String) {
        liveReplyBuffer += token
        guard liveReplyFlushTask == nil else { return }
        liveReplyFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            self.liveReplyFlushTask = nil
            self.flushLiveReply()
        }
    }

    /// Push any staged tokens into `liveReply` immediately (turn end, reset).
    private func flushLiveReply() {
        liveReplyFlushTask?.cancel()
        liveReplyFlushTask = nil
        guard !liveReplyBuffer.isEmpty else { return }
        liveReply += liveReplyBuffer
        liveReplyBuffer = ""
    }

    private func resetLiveReply() {
        liveReplyFlushTask?.cancel()
        liveReplyFlushTask = nil
        liveReplyBuffer = ""
        liveReply = ""
    }

    // MARK: - Public lifecycle

    /// Start a fresh voice conversation. Asks for mic + speech permission on
    /// first use. Returns false if either is denied.
    func start() async -> Bool {
        modelRestoreTask?.cancel()
        modelRestoreTask = nil
        switch phase {
        case .idle, .failed: break          // allowed to (re)start
        default:             return true    // already running
        }

        let ok = await dictation.requestAuthorization()
        guard ok else {
            phase = .failed("Microphone or speech recognition permission denied.")
            return false
        }

        // Bring the shared audio session into the listening configuration.
        // Speaking later drops HFP so TTS isn't pinned to 8 kHz Bluetooth.
        do {
            try applyConversationSession(forSpeaking: false)
        } catch {
            // Don't leave a stale playAndRecord session pinned — that
            // forces every later standalone TTS through the zombie path.
            teardownPlaybackSession()
            phase = .failed("Audio session error: \(error.localizedDescription)")
            return false
        }

        await applyVoiceModelOverrideIfNeeded()
        await voice.load()

        // The assistant LLM must be resident to answer — start() previously
        // loaded only the TTS engine, so first-use voice (no chat model
        // preloaded and no voice-model override) dead-ended on the first turn.
        // Kick the load off now, non-blocking, so weights are ready by the
        // time the user finishes their first sentence. switchTo (from the
        // override path) may already have it loading; load() is a no-op then.
        switch assistant.state {
        case .ready, .loading, .generating: break
        default: Task { [assistant] in await assistant.load() }
        }

        session = [ChatMessage(
            role: .system,
            content: PersonaStore.shared.active.systemPrompt
                + "\n\n" + CodingAssistantService.groundingPrompt
        )]
        resetLiveReply()
        liveTranscript = ""
        pendingTranscript = ""
        SpeechPlaybackCoordinator.shared.reset()
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.listening)

        // Start the mic in continuous mode. The dictation service won't
        // deactivate the session on cleanup, leaving it hot for TTS.
        let handler: (String, Bool) -> Void = { [weak self] text, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.liveTranscript = text
                // Stamp the change time only when the text actually moves,
                // so "unchanged for N seconds" reflects the user pausing —
                // not the recogniser re-emitting the same partial.
                if text != self.pendingTranscript {
                    self.pendingTranscript = text
                    self.lastTranscriptChangeAt = Date()
                }
            }
        }
        continuousTranscriptHandler = handler
        do {
            try dictation.start(continuous: true, handler)
        } catch {
            teardownPlaybackSession()
            phase = .failed(error.localizedDescription)
            return false
        }

        installSessionObservers()
        phase = .listening
        startVADLoop()
        return true
    }

    /// End the conversation entirely — closes mic, stops playback, resets.
    func stop() {
        vadTask?.cancel()
        vadTask = nil
        replyTask?.cancel()
        replyTask = nil
        editedTurnTask?.cancel()
        editedTurnTask = nil
        removeSessionObservers()
        phaseBeforeInterruption = nil
        dictation.stop()
        voice.stop()
        assistant.stopGeneration()
        continuousTranscriptHandler = nil
        phase = .idle
        liveTranscript = ""
        resetLiveReply()
        SpeechPlaybackCoordinator.shared.reset()

        // Now that nothing else needs audio, give the session back AND
        // leave `.playback` (not a stale `.playAndRecord`). Leaving
        // playAndRecord active after voice mode was the Bluetooth HFP
        // 8 kHz "zombie voice" path for every later Apple System TTS.
        teardownPlaybackSession()

        modelRestoreTask?.cancel()
        modelRestoreTask = Task { [weak self] in
            await self?.restoreChatModelIfNeeded()
        }
    }

    /// User-triggered "interrupt the LLM and start listening again."
    /// Audio stop is synchronous and first; state reconciliation follows.
    func interrupt() async {
        // Generation bump + audible stop before any awaitable work.
        voice.stop()
        SpeechPlaybackCoordinator.shared.interruptImmediately()
        replyTask?.cancel()
        replyTask = nil
        assistant.stopGeneration()
        // Return to listening cleanly: reset accumulators, restart recogniser.
        pendingTranscript = ""
        liveTranscript = ""
        // Restore mic-capable route + engine before listening again.
        try? applyConversationSession(forSpeaking: false)
        guard resumeListeningOrFail() else { return }
    }

    /// True while voice conversation owns the shared audio session for
    /// duplex mic work. TTS speaking deliberately uses `.playback` and
    /// must NOT trip the "leave playAndRecord alone" early-returns in
    /// VoiceService / SystemSpeechService — those were leaving Apple
    /// TTS on the full-duplex zombie path.
    var isHoldingRecordSession: Bool {
        switch phase {
        case .listening, .thinking: return true
        case .speaking, .idle, .failed: return false
        }
    }

    /// Public entry for in-conversation TTS (reply stream + Test audio).
    /// Flips to `.playback` and stops the mic engine so Apple System Voice
    /// isn't thinned by a live playAndRecord route.
    func prepareForTTSPlayback() {
        try? applyConversationSession(forSpeaking: true)
        // Standalone speak()/Test audio never went through streamReply's
        // phase bind — without this the orb stayed on listening and ignored
        // playback levels (glass output gate stayed closed).
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.speaking)
    }

    /// Restore mic-capable session after a one-shot TTS (Test audio) while
    /// still in voice mode. No-op when conversation isn't listening.
    func restoreListeningAfterTTS() {
        guard case .listening = phase else { return }
        try? applyConversationSession(forSpeaking: false)
        _ = resumeListeningOrFail()
    }

    /// Resume continuous dictation and publish `.listening`. On failure,
    /// try a hard restart of the continuous mic session before failing the
    /// conversation — soft resume often no-ops after the first TTS route flip.
    @discardableResult
    private func resumeListeningOrFail() -> Bool {
        if dictation.resumeRecognition() {
            phase = .listening
            SpeechPlaybackCoordinator.shared.bindSessionPhase(.listening)
            return true
        }
        if hardRestartContinuousDictation() {
            phase = .listening
            SpeechPlaybackCoordinator.shared.bindSessionPhase(.listening)
            return true
        }
        let message = dictation.lastError ?? "Microphone unavailable."
        phase = .failed(message)
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.failed(message))
        return false
    }

    /// Tear down and rebuild continuous dictation after a failed soft resume.
    @discardableResult
    private func hardRestartContinuousDictation() -> Bool {
        guard let handler = continuousTranscriptHandler else { return false }
        dictation.stop()
        do {
            try applyConversationSession(forSpeaking: false)
            try dictation.start(continuous: true, handler)
            return true
        } catch {
            print("[VoiceConversation] hard mic restart failed: \(error)")
            return false
        }
    }

    /// Listening: `.playAndRecord` + HFP so a headset mic works.
    /// Speaking: `.playback` so Apple / neural TTS is not forced through
    /// a full-duplex / HFP path (the thin "zombie" synthetic voice).
    private func applyConversationSession(forSpeaking: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if forSpeaking {
            // Mic must be quiet before flipping category — otherwise
            // AVAudioEngine holds the session in a voice-processing route.
            dictation.pauseEngineForTTS()
            // Playback already routes to A2DP automatically. The explicit
            // allowBluetoothA2DP flag is valid for input-capable categories,
            // not `.playback`; keeping it here could fail the transition and
            // strand TTS on the old HFP/full-duplex "zombie" route.
            let desiredOptions: AVAudioSession.CategoryOptions = [.duckOthers]
            let alreadyConfigured =
                session.category == .playback &&
                session.mode == .spokenAudio &&
                session.categoryOptions.contains(.duckOthers)
            if !alreadyConfigured {
                if session.category == .playAndRecord || session.category == .record {
                    try? session.setActive(false, options: [])
                }
                try session.setCategory(.playback, mode: .spokenAudio, options: desiredOptions)
            }
            try session.setActive(true, options: [])
            return
        }

        let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .duckOthers, .allowBluetoothHFP]
        let alreadyConfigured =
            session.category == .playAndRecord &&
            session.mode == .spokenAudio &&
            session.categoryOptions == options
        if !alreadyConfigured {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: options)
        }
        try session.setActive(true, options: [])
    }

    /// Clear a failed/abandoned conversation session so later TTS isn't
    /// stuck on playAndRecord.
    private func teardownPlaybackSession() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: - Voice-mode model override

    var voiceModelID: String? {
        let raw = AppSettings.shared.voiceConversationModelID
        return raw.isEmpty ? nil : raw
    }

    func setVoiceModel(_ id: String?) async {
        AppSettings.shared.voiceConversationModelID = id ?? ""
        if phase != .idle {
            await applyVoiceModelOverrideIfNeeded(force: true)
        }
    }

    private func applyVoiceModelOverrideIfNeeded(force: Bool = false) async {
        guard let voiceID = voiceModelID else { return }
        let current = assistant.activeModel.id
        guard force || current != voiceID else { return }
        if savedChatModelID == nil {
            savedChatModelID = current
        }
        if let preset = AssistantModelCatalog.model(forID: voiceID) {
            await assistant.switchTo(preset, persistAsDefault: false)
            return
        }
        if let model = LocalModelRegistry
            .descriptor(forStoredAssistantID: voiceID, catalog: ModelDownloadCenter.shared.models)?
            .assistantModel {
            await assistant.switchTo(model, persistAsDefault: false)
            return
        }
    }

    private func restoreChatModelIfNeeded() async {
        guard let saved = savedChatModelID else { return }
        savedChatModelID = nil
        guard assistant.activeModel.id != saved else { return }
        // Restore the selection WITHOUT loading — switchTo here eagerly
        // reloaded the multi-GB chat model just because voice mode ended.
        // generate()'s lazy-load path loads it on the next chat send.
        if let preset = AssistantModelCatalog.model(forID: saved) {
            await assistant.adoptSelectionWithoutLoading(preset)
        } else if let restored = AssistantModelCatalog.selection(forStoredID: saved) {
            await assistant.adoptSelectionWithoutLoading(restored)
        }
    }

    // MARK: - Listening loop
    //
    // Single long-running task that drives turn-taking. Each tick it pulls the
    // mic level, asks the VoiceActivityDetector for p(speech), and feeds the
    // TurnEndpointer, which decides turn start/end and barge-in. The detection
    // characteristics (noise floor, thresholds, adaptive end-of-turn, barge-in
    // arming) all live in Services/Voice/Listening/ now; this loop is just the
    // wiring. Cancelled in stop().
    private func startVADLoop() {
        vadTask?.cancel()
        vadTask = Task { [weak self] in
            await self?.runVADLoop()
        }
    }

    private func runVADLoop() async {
        let detector = VADFactory.makeDetector()
        let endpointer = TurnEndpointer()
        var orbLevel: Float = 0
        var lastPhase: Phase = .idle

        while !Task.isCancelled {
            let current = phase

            // Reset detection state on every phase transition so a turn never
            // inherits the previous phase's accumulators / noise floor.
            if current != lastPhase {
                switch current {
                case .listening:
                    detector.reset(); endpointer.resetListening()
                    // Fresh turn — don't let a stale stamp from the previous
                    // turn instantly trip the stability net.
                    lastTranscriptChangeAt = nil
                case .speaking:  endpointer.resetSpeaking()
                default:         break
                }
                lastPhase = current
            }

            // VAD only matters while listening (turn-taking) or speaking
            // (barge-in). Idle / thinking / failed: rest the orb and poll at a
            // relaxed ~10 Hz instead of the 50 Hz turn-taking cadence — nothing
            // consumes the mic in these phases, so the faster wakeups were pure
            // overhead. (Playback energy can't seed the next listening
            // calibration: the .listening transition above already calls
            // detector.reset().)
            guard current == .listening || current == .speaking else {
                if orbLevel != 0 {
                    orbLevel = 0
                    VoiceVisualLevelStore.shared.micLevel = 0
                }
                try? await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
                continue
            }

            let raw = dictation.levelMeter
            // Orb pulse rides its own light EMA so the animation stays smooth
            // and responsive independent of how the detector smooths.
            orbLevel = 0.35 * raw + 0.65 * orbLevel
            // Hot path for orb TimelineView — no SwiftUI invalidation.
            VoiceVisualLevelStore.shared.micLevel = orbLevel

            let now = Date()
            // 16 kHz mono frames captured since the last tick — the neural VAD
            // consumes them; the energy VAD ignores them and uses `raw`.
            let frames = dictation.drainVADFrames()
            // Off-main for the neural detector (CoreML inference) so the loop
            // doesn't block the main actor ~30×/s; awaited before the next tick
            // so the detector's state is never touched concurrently. The energy
            // detector runs inline via the protocol's default.
            let prob = await detector.speechProbabilityAsync(level: raw, frames: frames)

            if current == .speaking {
                if endpointer.observeSpeaking(probability: prob, now: now) == .bargeIn {
                    // Confirmed user speech over the assistant — interrupt()
                    // cancels the reply task + TTS, resumes recognition, and
                    // returns to .listening.
                    await interrupt()
                }
            } else {
                // Adaptive end-of-turn: how long we wait for silence depends
                // on whether the live transcript sounds finished.
                let completion = EndOfTurnEstimator.confidence(for: pendingTranscript)
                let event = endpointer.observeListening(probability: prob,
                                                        completion: completion,
                                                        now: now)
                if event == .turnStarted {
                    // Drive the orb into speechDetected so listening → speech
                    // animations actually fire (package states were unused).
                    SpeechPlaybackCoordinator.shared.bindSessionPhase(.speechDetected)
                }
                let vadEnded = event == .turnEnded
                // Safety net (see `transcriptStabilityEndOfTurn`): if the VAD
                // is stuck and never reports end-of-turn, fall back to the
                // recogniser. A non-empty transcript that has stopped changing
                // for the stability window means the user finished talking.
                //
                // Adaptive window: if the utterance already SOUNDS finished,
                // the base 2 s is enough. If it sounds mid-sentence (the user
                // just paused — low completion confidence), wait longer before
                // the rescue fires so we don't cut them off and send a
                // half-finished turn. The VAD still drives normal turn-taking;
                // this only governs the stuck-VAD fallback.
                let transcriptStalled: Bool = {
                    guard !pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let changed = lastTranscriptChangeAt else { return false }
                    let window = completion >= 0.5
                        ? transcriptStabilityEndOfTurn
                        : transcriptStabilityEndOfTurn + 1.5
                    return now.timeIntervalSince(changed) >= window
                }()
                if vadEnded || transcriptStalled {
                    let text = pendingTranscript
                    await handleEndOfTurn(text)
                    // If the turn was a no-op (empty transcript, or model not
                    // ready) we're still .listening — clear the endpointer so
                    // the same trailing silence doesn't immediately re-fire.
                    if phase == .listening {
                        detector.reset()
                        endpointer.resetListening()
                        lastTranscriptChangeAt = nil
                        SpeechPlaybackCoordinator.shared.bindSessionPhase(.listening)
                    }
                }
            }

            try? await Task.sleep(nanoseconds: UInt64(vadTickInterval * 1_000_000_000))
        }
    }

    // MARK: - LLM round-trip

    private func handleEndOfTurn(_ text: String) async {
        guard !Task.isCancelled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Heard "speech" but the recogniser produced nothing — probably
            // a cough or a non-speech sound. Reset state and keep listening.
            pendingTranscript = ""
            liveTranscript = ""
            return
        }

        // Stop transcribing — but keep the audio engine alive (so we still
        // get level data) and the audio session hot (so TTS plays).
        dictation.pauseRecognition()
        phase = .thinking
        resetLiveReply()
        SpeechPlaybackCoordinator.shared.beginUtterance()
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.thinking)

        session.append(ChatMessage(role: .user, content: trimmed))
        let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
        session.append(assistantMsg)

        // Ensure the assistant LLM is resident before generating. If it isn't
        // (first turn before the proactive load finished, or a prior load
        // failed), bring it up and wait briefly here rather than latching
        // .failed and stranding the mic on a dead orb.
        if assistant.state != .ready {
            switch assistant.state {
            case .unloaded, .failed: await assistant.load()
            default: break   // .loading already in progress
            }
            var waited = 0
            while assistant.state != .ready && waited < 100 {   // up to ~10 s
                guard !Task.isCancelled else { return }
                if case .failed = assistant.state { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
        }
        guard !Task.isCancelled else { return }
        guard assistant.state == .ready else {
            if case .failed(let msg) = assistant.state {
                // Genuine load failure (e.g. model too big for this device).
                pendingTranscript = ""
                liveTranscript = ""
                phase = .failed(msg)
            } else {
                // Still loading a cold/large model — keep the conversation
                // alive and let the user retry in a moment. KEEP the
                // transcript: clearing it here discarded the user's turn
                // whenever a cold load outran the 10 s wait above.
                ToastCenter.shared.info("Model still loading", detail: "Try again in a moment.")
                _ = resumeListeningOrFail()
            }
            return
        }

        // Fire-and-forget so the VAD loop keeps ticking through think+speak
        // and can detect barge-in. streamReply() owns the phase from here:
        // it flips to .speaking when the first chunk is ready and back to
        // .listening when the reply finishes (or interrupt() cancels it).
        replyTask?.cancel()
        replyTask = Task { [weak self] in
            await self?.streamReply()
        }
    }

    private func streamReply() async {
        // CodingAssistantService silently no-ops generate() while still
        // `.generating`. Wait briefly so turn 2 isn't dropped if turn 1's
        // native decode hasn't flipped back to `.ready` yet.
        var spins = 0
        while case .generating = assistant.state, spins < 80, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
            spins += 1
        }
        if Task.isCancelled { return }

        let history = session.dropLast()
        let speakAloud = AppSettings.shared.voiceAnswerEnabled
        let audioQueue: AudioQueue?
        if speakAloud {
            // Publish a fresh queue so the status pill sees `isSpeaking`
            // updates on this turn's instance. The previous turn's queue
            // is already in a terminal state (finish() called on it).
            self.currentAudioQueue = AudioQueue()
            audioQueue = self.currentAudioQueue
        } else {
            audioQueue = nil
        }
        // TTS pipeline state held across token callbacks. Two buffers
        // run in parallel:
        //
        //   • `liveReply` (in `self`) — RAW model output, including
        //     `<think>…</think>` reasoning. The UI binds to this so
        //     thinking-mode users see the scratch work intact.
        //
        //   • `speakable` (here)     — same stream with reasoning
        //     blocks stripped via `ReasoningStripper.feed(_:)`. The
        //     sentence-boundary cutter runs over THIS, not liveReply,
        //     so the TTS branch never narrates chain-of-thought.
        //
        // Per-sentence language detection runs on each emitted chunk
        // and the BCP-47 tag rides along on the `AudioQueue.Utterance`
        // to the voice/engine resolver, which picks a matching voice.
        //
        // Pipeline configuration comes from the active model's
        // `VoiceProfile`. A model with `usesReasoningTokens == false`
        // bypasses the stripper entirely (saves the per-token feed
        // cost); the chunking strategy and language-detection hints
        // both come from the profile.
        let profile = VoiceProfileRegistry.profile(for: assistant.activeModel.id)
        let stripper: ReasoningStripper? = profile.usesReasoningTokens
            ? ReasoningStripper(
                openTag:  profile.reasoningTokenPattern?.open  ?? "<think>",
                closeTag: profile.reasoningTokenPattern?.close ?? "</think>"
              )
            : nil
        let detector = LanguageDetector.shared
        let chunker  = SemanticChunker(strategy: profile.chunkingStrategy)
        let hints    = profile.dominantLanguages
        var startedSpeaking = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            assistant.generate(
                messages: Array(history),
                onToken: { [weak self] token in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // 1. UI receives the raw token unchanged — batched
                        //    (~8 Hz publish) so SwiftUI doesn't re-evaluate
                        //    the whole voice surface per token.
                        self.appendLiveReplyToken(token)

                        guard let audioQueue else { return }

                        // 2. TTS branch sees the (optionally) stripped
                        //    projection, fed into the chunker so the
                        //    sentence-boundary state lives inside one
                        //    object rather than parallel scalars. When
                        //    the active profile has no reasoning
                        //    tokens (`usesReasoningTokens == false`),
                        //    `stripper` is nil and we pass the token
                        //    through unchanged.
                        let filtered = stripper?.feed(token) ?? token
                        guard !filtered.isEmpty else { return }
                        // Karaoke follows speakable text (not <think> blocks).
                        SpeechPlaybackCoordinator.shared.appendKaraokeText(filtered)
                        let chunks = chunker.append(filtered)
                        guard !chunks.isEmpty else { return }

                        // 3. For each ready chunk, language-tag it
                        //    using the profile's `dominantLanguages`
                        //    as hints, and enqueue.
                        for chunk in chunks {
                            if !startedSpeaking {
                                startedSpeaking = true
                                // Drop Bluetooth HFP before the first TTS
                                // chunk so the utterance isn't 8 kHz mono.
                                try? self.applyConversationSession(forSpeaking: true)
                                self.phase = .speaking
                                SpeechPlaybackCoordinator.shared.bindSessionPhase(.speaking)
                                self.voice.speakStream(audioQueue)
                            }
                            let language = detector.detect(chunk.text, hints: hints)
                            audioQueue.enqueue(AudioQueue.Utterance(
                                text: chunk.text, language: language
                            ))
                        }
                    }
                },
                onComplete: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { continuation.resume(); return }
                        guard self.phase == .thinking || self.phase == .speaking else {
                            audioQueue?.stop()
                            continuation.resume()
                            return
                        }
                        self.flushLiveReply()
                        let finalText = self.liveReply
                        if let idx = self.session.lastIndex(where: { $0.role == .assistant }) {
                            self.session[idx].content = finalText
                            self.session[idx].isStreaming = false
                        }

                        if let audioQueue {
                            // Flush whatever the stripper still has
                            // buffered (a pending partial open-tag
                            // candidate that never completed, or just
                            // tail text after the last `</think>`).
                            // Drop an unclosed think block — flush()
                            // returns empty in that case. Profiles
                            // with no reasoning tokens skip this
                            // step entirely.
                            let trailing = stripper?.flush() ?? ""
                            if !trailing.isEmpty {
                                SpeechPlaybackCoordinator.shared.appendKaraokeText(trailing)
                                // Any sentence boundaries that close
                                // out IN this trailing batch flush
                                // first; whatever the chunker still
                                // holds after that lands in finish().
                                for chunk in chunker.append(trailing) {
                                    let language = detector.detect(chunk.text, hints: hints)
                                    audioQueue.enqueue(AudioQueue.Utterance(
                                        text: chunk.text, language: language
                                    ))
                                }
                            }
                            if let tail = chunker.finish() {
                                let language = detector.detect(tail.text, hints: hints)
                                audioQueue.enqueue(AudioQueue.Utterance(
                                    text: tail.text, language: language
                                ))
                            }
                            audioQueue.finish()
                            if !startedSpeaking {
                                // Edge case: no sentence boundary was ever
                                // detected (very short reply, or a reply
                                // with no terminal punctuation). The
                                // remainder push above was the only chunk
                                // — kick off the stream now.
                                startedSpeaking = true
                                try? self.applyConversationSession(forSpeaking: true)
                                self.phase = .speaking
                                SpeechPlaybackCoordinator.shared.bindSessionPhase(.speaking)
                                self.voice.speakStream(audioQueue)
                            }
                            await self.waitForSpeechCompletion()
                            // Always return the mic after a spoken reply unless
                            // the user already interrupted back to listening or
                            // ended the session. Previously we required
                            // `.speaking`, so a race that cleared isPlaying
                            // early could strand the session mid-phase.
                            if !Task.isCancelled {
                                switch self.phase {
                                case .speaking, .thinking:
                                    self.pendingTranscript = ""
                                    self.liveTranscript = ""
                                    try? self.applyConversationSession(forSpeaking: false)
                                    _ = self.resumeListeningOrFail()
                                default:
                                    break
                                }
                            }
                        } else {
                            // Voice-answer toggle is OFF — show the reply
                            // silently and hand the mic straight back.
                            self.pendingTranscript = ""
                            self.liveTranscript = ""
                            try? self.applyConversationSession(forSpeaking: false)
                            _ = self.resumeListeningOrFail()
                        }
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Sentence-boundary detection lives in `SemanticChunker` now —
    /// see Services/Voice/Pipeline/SemanticChunker.swift.

    private func waitForSpeechCompletion() async {
        // 5 minutes is well above any plausible spoken reply (the longest
        // ~2000-token answer at 150wpm is ~10 minutes, but the streaming
        // path means we're only blocking until the queue drains — not
        // generation). The deadline is a safety net against deadlocks.
        let deadline = Date().addingTimeInterval(300)
        while !Task.isCancelled
                && voice.isPlaying
                && phase == .speaking
                && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                // Cooperative cancel from interrupt()/stop() — exit immediately
                // so a new turn isn't blocked by an orphaned wait loop.
                return
            }
        }
    }

    // MARK: - Audio session resilience
    //
    // Three notifications cover the failure modes the conversation can hit
    // while the user is mid-turn:
    //
    //   • interruptionNotification     phone calls, Siri, alarms
    //   • routeChangeNotification      AirPods plug/unplug, Bluetooth swap,
    //                                  CarPlay attach
    //   • mediaServicesWereResetNotification
    //                                  rare iOS audio-server reset where
    //                                  every previously created object is
    //                                  now invalid
    //
    // We install all three on start() and tear them down on stop(). The
    // notifications come in on a background thread; everything we touch
    // here is @MainActor, so we hop via Task { @MainActor in … }.

    private func installSessionObservers() {
        removeSessionObservers()
        let center = NotificationCenter.default
        let audio = AVAudioSession.sharedInstance()

        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: audio, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(note)
                }
            }
        )

        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification,
                               object: audio, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(note)
                }
            }
        )

        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                               object: audio, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            }
        )
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        for token in sessionObservers { center.removeObserver(token) }
        sessionObservers.removeAll()
    }

    /// Phone call / Siri / alarm. On .began iOS has already stolen the
    /// session; we just record where we were so .ended can restore. On
    /// .ended we reactivate the session and resume the recogniser if iOS
    /// signalled `.shouldResume` (it skips that flag when the user
    /// explicitly handed control elsewhere — e.g. answered the call —
    /// and we should respect that by staying paused).
    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            phaseBeforeInterruption = phase
            voice.stop()
            assistant.stopGeneration()
            dictation.pauseRecognition()
            // Don't transition to .failed — this is a recoverable pause,
            // not a hard error. Holding .listening keeps the UI calm.
            phase = .listening

        case .ended:
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume) else {
                // iOS says don't resume automatically. Stop cleanly so the
                // user can re-enter voice mode when they're ready instead
                // of leaving a half-dead session on screen.
                stop()
                return
            }
            reactivateSessionAndResume()

        @unknown default:
            break
        }
    }

    /// Headphones unplugged or Bluetooth route lost. iOS pauses the
    /// session for us; we just need to stop the in-flight TTS so it
    /// doesn't blast out of the iPhone speaker the moment the user
    /// pulls an AirPod, and surface a toast so the UI explains itself.
    /// New devices (AirPods reconnect, CarPlay attach) need no action —
    /// the session is already routed correctly by the time we hear
    /// about it.
    private func handleRouteChange(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            // The previous output is gone. If we were speaking, killing
            // playback prevents the "blasts out of the phone speaker"
            // failure mode.
            if phase == .speaking { voice.stop() }
            ToastCenter.shared.info(
                "Audio route changed",
                detail: "Output device disconnected — continuing on the current route."
            )

        case .newDeviceAvailable, .categoryChange, .override, .wakeFromSleep,
             .noSuitableRouteForCategory, .routeConfigurationChange, .unknown:
            // No action — either we're already configured (new device)
            // or there's nothing we can do (no suitable route).
            break

        @unknown default:
            break
        }
    }

    /// iOS occasionally tears down the entire audio server (out-of-memory,
    /// driver crash, device boot). Every AVAudioEngine / AVAudioSession
    /// object we created is now invalid — Apple's guidance is to rebuild
    /// from scratch. We stop the loop, mark the conversation failed (the
    /// user can tap End and re-enter), and emit a toast so they know what
    /// happened.
    private func handleMediaServicesReset() {
        vadTask?.cancel()
        vadTask = nil
        voice.stop()
        assistant.stopGeneration()
        dictation.stop()
        phase = .failed("Audio system was reset. Tap End, then re-enter voice mode.")
        ToastCenter.shared.info(
            "Audio system reset",
            detail: "Restart voice mode to continue."
        )
    }

    /// Reactivate the shared session after iOS hands it back, then turn
    /// the recogniser back on so the next user turn is heard. Used by the
    /// interruption-ended branch. Failure surfaces as a recoverable
    /// `.failed` phase rather than crashing the loop.
    ///
    /// Always resumes listening: interruption handling already stopped TTS
    /// and generation, so restoring `.speaking` / `.thinking` would leave
    /// a dead phase on screen.
    private func reactivateSessionAndResume() {
        phaseBeforeInterruption = nil
        do {
            try applyConversationSession(forSpeaking: false)
        } catch {
            phase = .failed("Couldn't reactivate audio after interruption.")
            SpeechPlaybackCoordinator.shared.bindSessionPhase(
                .failed("Couldn't reactivate audio after interruption.")
            )
            return
        }
        pendingTranscript = ""
        liveTranscript = ""
        _ = resumeListeningOrFail()
    }

    // MARK: - Transcript Editing (Feature #10)

    /// Prompts the user with the pending transcript so they can edit
    /// before sending. Returns the edited text or nil if the user cancelled.
    /// Called from the voice UI when `transcriptEditingEnabled` is true
    /// and a turn ends.
    @Published var editableTranscript: String = ""
    @Published var showTranscriptEditor: Bool = false

    /// Mark the current transcript as editable. The voice UI presents an
    /// inline text field. Returns the edited text or the original if the
    /// user dismissed without changing.
    func presentTranscriptForEditing() -> String {
        let text = pendingTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        editableTranscript = text
        showTranscriptEditor = true
        return text
    }

    /// Accept the edited transcript and proceed to LLM.
    func acceptEditedTranscript() {
        showTranscriptEditor = false
        let text = editableTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            pendingTranscript = ""
            liveTranscript = ""
            _ = resumeListeningOrFail()
            return
        }
        pendingTranscript = text
        liveTranscript = text
        editedTurnTask?.cancel()
        editedTurnTask = Task { [weak self] in
            await self?.handleEndOfTurn(text)
        }
    }

    /// Dismiss the transcript editor without sending.
    func cancelTranscriptEditing() {
        showTranscriptEditor = false
        // Resume listening — discard the turn.
        pendingTranscript = ""
        liveTranscript = ""
        _ = resumeListeningOrFail()
    }

    // MARK: - Persona Voice Profiles (Feature #10)

    /// Resolve the voice for the active persona. If a persona-specific
    /// voice is configured, use it; otherwise fall back to the global default.
    func voiceForActivePersona() -> VoiceOption? {
        guard let data = AppSettings.shared.personaVoiceProfileJSON.data(using: .utf8),
              let profiles = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }

        let personaID = PersonaStore.shared.active.id
        guard let voiceID = profiles[personaID] else { return nil }

        return VoiceService.shared.availableVoices.first { $0.id == voiceID }
    }
}
