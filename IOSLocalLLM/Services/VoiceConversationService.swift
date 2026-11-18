import Foundation
import Combine
import AVFoundation
import os

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
        /// Mic and generation stopped but the conversation is kept: a phone
        /// call / Siri took the audio session, or the app went to the
        /// background. `start()` resumes with the same history.
        case paused
        case failed(String)
    }

    /// Appended to the voice system prompt. Chat defaults (Markdown, up to
    /// 2K tokens, thinking) made every spoken turn a long, hot decode: the
    /// phone throttled after a few exchanges and replies stalled. Short
    /// spoken answers keep turns fast and the device cool.
    nonisolated static let spokenStylePrompt = """
    Voice conversation:
    - Your reply is read aloud by text-to-speech. Talk like a person: usually one to three short sentences.
    - Use plain words only. No Markdown, lists, tables, code, emoji, or URLs.
    - If the user asks for more detail, continue in short spoken paragraphs.
    """

    /// Output cap for one spoken turn (~2 minutes of speech).
    static var voiceMaxTokens: Int { min(AppSettings.shared.assistantMaxTokens, 512) }

    // MARK: - Published

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var liveReply: String = ""
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
    private var nativePreRoll: [Float] = []
    private var nativeTurnFrames: [Float] = []
    private var nativeTurnActive = false
    /// Lead-in samples at onset; the rest of the turn is post-onset speech.
    private var nativeOnsetCount = 0
    private var pendingNativeInput: [Float]?
    /// Restores the chat model after voice mode stops. Stored so a rapid
    /// stop/start can cancel a stale restore before it races the new session.
    private var modelRestoreTask: Task<Void, Never>?
    /// Bumped by start / stop / suspend. `start()` re-checks it after every
    /// await: closing voice mode while the TTS engine was still loading used
    /// to let start() finish afterwards and leave the mic running with no UI.
    private var lifecycleToken: UInt64 = 0
    /// Bumped when a turn is committed or abandoned (interrupt, stop, call).
    /// Generation callbacks carry the value they started with so a late
    /// token or onComplete from a cancelled reply can't write into the next
    /// turn or flip its phase.
    private var turnID: UInt64 = 0
    /// Last time the VAD loop tried to revive a dead mic (rate limit).
    private var lastMicRecovery = Date.distantPast
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

    /// Start voice mode. From `.idle` this is a fresh conversation; from
    /// `.paused` / `.failed` it resumes with the same history. Asks for mic +
    /// speech permission on first use. Returns false if either is denied or
    /// voice mode was closed while starting.
    func start() async -> Bool {
        modelRestoreTask?.cancel()
        modelRestoreTask = nil
        let fresh: Bool
        switch phase {
        case .idle:              fresh = true
        case .paused, .failed:   fresh = session.isEmpty
        default:                 return true    // already running
        }
        lifecycleToken &+= 1
        let token = lifecycleToken

        let ok = await dictation.requestAuthorization()
        guard token == lifecycleToken else { return false }
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
        guard token == lifecycleToken else { return false }
        await voice.load()
        guard token == lifecycleToken else { return false }

        // Opening voice mode must never become a silent multi-GB download:
        // load() downloads a missing model by default. With nothing on disk
        // there is nothing to talk to — say so instead of listening.
        let assistantLoading: Bool = { if case .loading = assistant.state { return true }; return false }()
        if assistant.activeExecutionLocation == .localDownloaded,
           !assistant.selectedModelIsInstalled, !assistantLoading {   // a confirmed download in flight is fine
            teardownPlaybackSession()
            phase = .failed("\(assistant.activeModel.displayName) isn't downloaded. Download it in Models, or pick a downloaded model above.")
            return false
        }

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

        if fresh {
            session = [ChatMessage(
                role: .system,
                content: PersonaStore.shared.active.systemPrompt
                    + "\n\n" + CodingAssistantService.groundingPrompt
                    + "\n\n" + Self.spokenStylePrompt
            )]
        }
        resetLiveReply()
        liveTranscript = ""
        pendingTranscript = ""
        clearNativeAudio()
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
        // A paused/failed session can still hold a stopped recorder;
        // start() is a silent no-op while `isRecording`, so reset it.
        dictation.stop()
        do {
            try dictation.start(continuous: true, handler)
        } catch {
            // Right after the first permission prompt the input route can
            // still report 0 Hz for a moment, so every first-time user got
            // "Microphone isn't ready" on their first try. One short retry.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard token == lifecycleToken else { return false }
            do {
                try applyConversationSession(forSpeaking: false)
                try dictation.start(continuous: true, handler)
            } catch {
                teardownPlaybackSession()
                phase = .failed(error.localizedDescription)
                return false
            }
        }

        installSessionObservers()
        phase = .listening
        startVADLoop()
        return true
    }

    /// End the conversation entirely — closes mic, stops playback, resets.
    func stop() {
        teardown()
        phase = .idle
        SpeechPlaybackCoordinator.shared.reset()

        modelRestoreTask?.cancel()
        modelRestoreTask = Task { [weak self] in
            await self?.restoreChatModelIfNeeded()
        }
    }

    /// App went to the background: release the mic and stop generation —
    /// GPU work and a hot mic are not allowed / not wanted there, and the
    /// old code kept the loop running and resumed listening in the
    /// background after LifecycleController cancelled the reply. History
    /// is kept; `start()` resumes the conversation.
    func suspend() {
        switch phase {
        case .idle, .failed: return
        default: break
        }
        teardown()
        phase = .paused
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.paused)
    }

    /// Shared by stop() / suspend(): everything except the final phase.
    private func teardown() {
        lifecycleToken &+= 1
        turnID &+= 1
        finalizeAssistantTurn(interrupted: true)
        clearNativeAudio()
        vadTask?.cancel()
        vadTask = nil
        replyTask?.cancel()
        replyTask = nil
        removeSessionObservers()
        dictation.stop()
        voice.stop()
        AudioPlaybackService.shared.stop()
        assistant.stopGeneration()
        continuousTranscriptHandler = nil
        pendingTranscript = ""
        liveTranscript = ""
        resetLiveReply()

        // Now that nothing else needs audio, give the session back AND
        // leave `.playback` (not a stale `.playAndRecord`). Leaving
        // playAndRecord active after voice mode was the Bluetooth HFP
        // 8 kHz "zombie voice" path for every later Apple System TTS.
        teardownPlaybackSession()
    }

    /// Stops the reply and parks voice mode with the mic off and the error
    /// on screen. Leaving the recogniser running behind a failure banner
    /// kept transcribing (heat, battery) with nothing consuming it.
    private func fail(_ message: String) {
        turnID &+= 1
        finalizeAssistantTurn(interrupted: true)
        voice.stop()
        AudioPlaybackService.shared.stop()
        dictation.pauseEngineForTTS()
        clearNativeAudio()
        pendingTranscript = ""
        liveTranscript = ""
        phase = .failed(message)
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.failed(message))
    }

    /// Closes the in-flight assistant turn. Keeps whatever was generated so
    /// the model knows what it already said after a barge-in; an empty turn
    /// is dropped later by `sanitizedHistory`.
    private func finalizeAssistantTurn(interrupted: Bool) {
        flushLiveReply()
        guard let idx = session.lastIndex(where: { $0.role == .assistant }),
              session[idx].isStreaming else { return }
        session[idx].content = liveReply
        session[idx].isStreaming = false
        session[idx].wasInterrupted = interrupted
    }

    /// Voice turns can end without a reply (barge-in before the first token,
    /// a thermal refusal, a model that was still loading). Drop empty
    /// assistant turns and merge the user turns they leave back-to-back:
    /// several chat templates (Gemma, Mistral) reject non-alternating roles,
    /// and an empty assistant turn teaches the model to answer with nothing.
    nonisolated static func sanitizedHistory(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for message in messages {
            if message.role == .assistant,
               message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            if message.role == .user, let last = out.last, last.role == .user {
                out[out.count - 1].content += "\n" + message.content
                continue
            }
            out.append(message)
        }
        return out
    }

    /// User-triggered "interrupt the LLM and start listening again."
    /// Audio stop is synchronous and first; state reconciliation follows.
    func interrupt() async {
        turnID &+= 1
        finalizeAssistantTurn(interrupted: true)
        clearNativeAudio()
        // Generation bump + audible stop before any awaitable work.
        voice.stop()
        AudioPlaybackService.shared.stop()
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
        case .speaking, .paused, .idle, .failed: return false
        }
    }

    /// Public entry for in-conversation TTS (reply stream + Test audio).
    /// Flips to `.playback` and stops the mic engine so Apple System Voice
    /// isn't thinned by a live playAndRecord route.
    func prepareForTTSPlayback() {
        try? applyConversationSession(forSpeaking: true)
        // A one-shot (Test audio / Replay) is the assistant speaking: the
        // mic is off now, so `.listening` would be a lie and would trip the
        // dead-mic watchdog into reopening the mic mid-playback. It also
        // puts Interrupt on the dock.
        if phase == .listening { phase = .speaking }
        // Standalone speak()/Test audio never went through streamReply's
        // phase bind — without this the orb stayed on listening and ignored
        // playback levels (glass output gate stayed closed).
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.speaking)
    }

    /// Restore mic-capable session after a one-shot TTS (Test audio) while
    /// still in voice mode. No-op when the conversation isn't running.
    func restoreListeningAfterTTS() {
        switch phase {
        case .listening, .speaking: break
        default: return
        }
        try? applyConversationSession(forSpeaking: false)
        _ = resumeListeningOrFail()
    }

    /// Resume continuous dictation and publish `.listening`. On failure,
    /// try a hard restart of the continuous mic session before failing the
    /// conversation — soft resume often no-ops after the first TTS route flip.
    @discardableResult
    private func resumeListeningOrFail() -> Bool {
        clearNativeAudio()
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

    /// An explicit pick from the voice menus. The UI confirms the download
    /// size first for a model that isn't on disk; this call may download it.
    func setVoiceModel(_ id: String?) async {
        if assistant.activeModel.supportsNativeAudio && phase != .idle { await interrupt() }
        AppSettings.shared.voiceConversationModelID = id ?? ""
        guard phase != .idle else { return }
        let resumeAfter: Bool
        switch phase {
        case .failed, .paused: resumeAfter = true
        default:               resumeAfter = false
        }
        if case .failed = phase {
            // Clear the old error (often "X isn't downloaded") while the new
            // pick downloads / loads; progress shows under the orb.
            phase = .paused
            SpeechPlaybackCoordinator.shared.bindSessionPhase(.paused)
        }
        if id == nil {
            // "Match chat tab": the override path is a no-op for nil, so the
            // voice model used to stay active for the rest of the session.
            await restoreChatModelIfNeeded()
        } else {
            await applyVoiceModelOverrideIfNeeded(force: true)
        }
        if resumeAfter {
            // Picked from a failure such as "isn't downloaded": go again.
            _ = await start()
        } else if assistant.state == .unloaded, assistant.selectedModelIsInstalled {
            Task { [assistant] in await assistant.load() }
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
            if force || CodingAssistantService.isInstalled(preset) {
                await assistant.switchTo(preset, persistAsDefault: false)
            } else {
                // A remembered pick that isn't on disk (download cancelled or
                // deleted): reopening voice mode must not re-download it.
                // Select it unloaded so start() reports "isn't downloaded".
                await assistant.adoptSelectionWithoutLoading(preset)
            }
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

            // Dead-mic watchdog. iOS stops the input engine on route changes
            // (AirPods connect/disconnect), Siri, or another app grabbing the
            // mic — no callback reaches us, the transcript just never moves,
            // and the screen said "Listening" forever ("voice just stops").
            // Rebuild it, at most once a second.
            if current == .listening, !dictation.isEngineRunning,
               Date().timeIntervalSince(lastMicRecovery) > 1 {
                lastMicRecovery = Date()
                print("[VoiceConversation] mic engine stopped while listening — restarting")
                pendingTranscript = ""
                liveTranscript = ""
                try? applyConversationSession(forSpeaking: false)
                _ = resumeListeningOrFail()
                continue
            }

            // VAD only matters while listening (turn-taking) or speaking
            // with a live mic (barge-in). Speaking normally stops the mic
            // engine (see applyConversationSession), so polling at 50 Hz
            // then only fed zeros to the detector. Everything else: rest the
            // orb and poll at a relaxed ~10 Hz. (Playback energy can't seed
            // the next listening calibration: the .listening transition
            // above already calls detector.reset().)
            let micLive = current == .listening
                || (current == .speaking && dictation.isEngineRunning)
            guard micLive else {
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
                if assistant.activeModel.supportsNativeAudio {
                    if !nativeTurnActive {
                        nativePreRoll.append(contentsOf: frames)
                        // 1 s lead-in: onset is confirmed ~0.3–0.5 s after the
                        // first syllable, which the model must still hear.
                        if nativePreRoll.count > 16_000 { nativePreRoll.removeFirst(nativePreRoll.count - 16_000) }
                    }
                    if event == .turnStarted {
                        nativeTurnActive = true
                        nativeTurnFrames = nativePreRoll
                        nativeOnsetCount = nativePreRoll.count
                    } else if nativeTurnActive {
                        nativeTurnFrames.append(contentsOf: frames.prefix(max(0, 480_000 - nativeTurnFrames.count)))
                    }
                }
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
                    // A native model hears the audio, not the transcript. While
                    // the VAD still hears speech, a recogniser that stopped
                    // updating (e.g. a language it can't transcribe) must not
                    // end the turn mid-sentence.
                    if assistant.activeModel.supportsNativeAudio && prob >= 0.5 { return false }
                    let window = completion >= 0.5
                        ? transcriptStabilityEndOfTurn
                        : transcriptStabilityEndOfTurn + 1.5
                    return now.timeIntervalSince(changed) >= window
                }()
                if vadEnded || transcriptStalled || nativeTurnFrames.count >= 480_000 {
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
        // Without a transcript, a native turn needs ≥ 0.6 s of audio after
        // onset — not a cough or the tail of the assistant's own voice.
        let nativeAudio = assistant.activeModel.supportsNativeAudio && !nativeTurnFrames.isEmpty
            && (!trimmed.isEmpty || nativeTurnFrames.count - nativeOnsetCount >= 9_600)
        guard !trimmed.isEmpty || nativeAudio else {
            // Heard "speech" but the recogniser produced nothing — probably
            // a cough or a non-speech sound. Reset state and keep listening.
            // The native capture must reset too, or it keeps recording until
            // the 30 s cap forces a turn made of background noise.
            clearNativeAudio()
            pendingTranscript = ""
            liveTranscript = ""
            return
        }

        // Stop transcribing — but keep the audio engine alive (so we still
        // get level data) and the audio session hot (so TTS plays).
        dictation.pauseRecognition()
        pendingNativeInput = nativeAudio ? nativeTurnFrames : nil
        nativeTurnFrames = []
        nativePreRoll = []
        nativeTurnActive = false
        phase = .thinking
        resetLiveReply()
        SpeechPlaybackCoordinator.shared.beginUtterance()
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.thinking)

        // Ensure the assistant LLM is resident before generating. If it isn't
        // (first turn before the proactive load finished, or a prior load
        // failed), bring it up and wait briefly here rather than latching
        // .failed and stranding the mic on a dead orb.
        if assistant.state != .ready {
            switch assistant.state {
            case .unloaded, .failed:
                // Same rule as start(): no implicit download from voice.
                guard assistant.activeExecutionLocation != .localDownloaded
                        || assistant.selectedModelIsInstalled else {
                    fail("\(assistant.activeModel.displayName) isn't downloaded. Download it in Models, or pick a downloaded model above.")
                    return
                }
                await assistant.load()
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
        // Interrupt / stop / a call during the wait already moved us on.
        guard !Task.isCancelled, phase == .thinking else { return }
        guard assistant.state == .ready else {
            if case .failed(let msg) = assistant.state {
                // Genuine load failure (e.g. model too big for this device).
                fail(msg)
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

        // Commit the turn only once it can actually run, so a dropped turn
        // never leaves a dangling user message / empty reply in history.
        turnID &+= 1
        session.append(ChatMessage(role: .user, content: trimmed.isEmpty ? "[Audio message]" : trimmed))
        session.append(ChatMessage(role: .assistant, content: "", isStreaming: true))

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

        if assistant.activeModel.supportsNativeAudio {
            let audio = pendingNativeInput
            pendingNativeInput = nil
            await streamNativeReply(audio: audio)
            return
        }

        let history = Self.sanitizedHistory(Array(session.dropLast()))
        let turn = turnID
        // Thermal / memory refusals and "model busy" arrive here. They used
        // to be dropped: the turn ended in silence and the next one did the
        // same — the "voice just stops" report. Surfaced in onComplete.
        let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
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
                messages: history,
                maxTokensOverride: Self.voiceMaxTokens,
                // Thinking adds a long silent decode before the first spoken
                // word (the stripper hides it from TTS anyway) — wrong
                // trade-off for a spoken back-and-forth.
                forceNoThinking: true,
                onToken: { [weak self] token in
                    Task { @MainActor [weak self] in
                        guard let self, self.turnID == turn else { return }
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
                        // Stale completion from an interrupted / abandoned
                        // turn: must not touch the next turn's session or phase.
                        guard self.turnID == turn,
                              self.phase == .thinking || self.phase == .speaking else {
                            audioQueue?.stop()
                            continuation.resume()
                            return
                        }
                        self.flushLiveReply()
                        if let error = failure.withLock({ $0 }),
                           self.liveReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            audioQueue?.stop()
                            self.fail(error)
                            continuation.resume()
                            return
                        }
                        self.finalizeAssistantTurn(interrupted: false)

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
                            if !Task.isCancelled, self.turnID == turn {
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
                },
                onError: { error in failure.withLock { $0 = error } }
            )
        }
    }

    private func clearNativeAudio() {
        nativeTurnFrames = []
        nativePreRoll = []
        nativeTurnActive = false
        nativeOnsetCount = 0
        pendingNativeInput = nil
    }

    private struct NativeReply: Sendable {
        var text = ""
        var error: String?
    }

    /// The player marks a buffer done once consumed, before its end leaves
    /// the speaker. Reopening the mic then let the model hear its own tail
    /// as a new turn; wait out the output latency plus room echo first.
    private func waitForNativeSpeechEnd() async {
        await AudioPlaybackService.shared.waitUntilQueueDrained()
        try? await Task.sleep(for: .seconds(AudioVisualClock.currentOutputPresentationLatency() + 0.25))
    }

    /// Speaks a text-only native reply with the app's voice, through the same
    /// chunking and language routing as the streamed text-model path.
    private func speakNativeTextReply(_ text: String) async {
        let profile = VoiceProfileRegistry.profile(for: assistant.activeModel.id)
        let chunker = SemanticChunker(strategy: profile.chunkingStrategy)
        let queue = AudioQueue()
        currentAudioQueue = queue
        try? applyConversationSession(forSpeaking: true)
        phase = .speaking
        SpeechPlaybackCoordinator.shared.bindSessionPhase(.speaking)
        voice.speakStream(queue)
        for chunk in chunker.append(text) + [chunker.finish()].compactMap({ $0 }) {
            queue.enqueue(AudioQueue.Utterance(
                text: chunk.text,
                language: LanguageDetector.shared.detect(chunk.text, hints: profile.dominantLanguages)
            ))
        }
        queue.finish()
        await waitForSpeechCompletion()
    }

    /// Voice has no file picker or approval card; `file_read` would only
    /// promise contents that never arrive, and calendar tools need approval.
    private static let voiceTools = LFM3ToolCodec.localTools.filter {
        $0.name != "file_read" && !PersonalDataTool.names.contains($0.name)
    }

    /// Audio stays in memory for one turn. Native tool calls pass through the
    /// same local runner as chat. Web access follows its setting; "ask every
    /// time" returns an error because Voice cannot show the consent sheet.
    private func streamNativeReply(audio: [Float]?) async {
        let toolsEnabled = AppSettings.shared.toolsEnabled && assistant.activeModel.supportsTools
        let speak = AppSettings.shared.voiceAnswerEnabled
        let turn = turnID
        for _ in 0..<4 {
            guard !Task.isCancelled else { return }
            let reply = OSAllocatedUnfairLock(initialState: NativeReply())
            var history = Self.sanitizedHistory(Array(session.dropLast()))
            let voiceInstruction: String
            if toolsEnabled {
                voiceInstruction = speak
                    ? "Respond with function calls, and interleaved text and audio."
                    : "Respond with function calls, and text."
            } else {
                voiceInstruction = speak
                    ? "Respond with interleaved text and audio."
                    : "Respond in text."
            }
            if toolsEnabled {
                history.insert(ChatMessage(role: .system, content:
                    voiceInstruction + "\n\n" + LFM3ToolCodec.instructions(tools: Self.voiceTools)
                ), at: 0)
            } else {
                history.insert(ChatMessage(role: .system, content:
                    voiceInstruction + ToolRunner.unavailablePromptAddendum
                ), at: 0)
            }
            // Speech plays as the codec emits it instead of after the whole
            // reply, and the speaking phase re-arms barge-in while the rest
            // is still generating. One consumer keeps chunks in order. The
            // codec yields 80 ms frames: buffer 0.6 s before starting and
            // schedule ≥ 0.2 s at a time, so a brief generation stall does
            // not chop the voice.
            let (speech, speechSink) = AsyncStream.makeStream(of: ([Float], Double).self)
            let player = Task { @MainActor [weak self] () -> Bool in
                var started = false
                var pending: [Float] = []
                var rate = 24_000.0
                @MainActor func play(_ samples: [Float]) async {
                    guard let self, !Task.isCancelled,
                          let buffer = AudioPlaybackService.makeBuffer(from: samples, sampleRate: rate) else { return }
                    if !started {
                        started = true
                        try? self.applyConversationSession(forSpeaking: true)
                        self.phase = .speaking
                        SpeechPlaybackCoordinator.shared.bindSessionPhase(.speaking)
                        AudioPlaybackService.shared.beginUtteranceTimeline(sampleRate: rate)
                    }
                    await AudioPlaybackService.shared.schedule(buffer: buffer)
                }
                for await (samples, sampleRate) in speech {
                    rate = sampleRate
                    pending += samples
                    guard Double(pending.count) >= rate * (started ? 0.2 : 0.6) else { continue }
                    let ready = pending
                    pending.removeAll(keepingCapacity: true)
                    await play(ready)
                }
                if !pending.isEmpty { await play(pending) }
                return started
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    assistant.generate(
                        messages: history,
                        // Every round re-attaches the user's audio to their turn,
                        // so a follow-up after a tool call still hears the question
                        // when the recognizer produced no transcript.
                        audioInput: audio,
                        generateSpeech: speak,
                        // With tools on, let LFM3 choose between a native call
                        // and speech instead of forcing a mixed audio prefill.
                        letModelChooseAudio: toolsEnabled,
                        onAudioChunk: { samples, rate in speechSink.yield((samples, rate)) },
                        onToken: { [weak self] token in
                            reply.withLock { $0.text += token }
                            Task { @MainActor [weak self] in
                                guard let self, self.turnID == turn else { return }
                                self.appendLiveReplyToken(token)
                            }
                        },
                        onComplete: { _ in continuation.resume() },
                        onError: { error in reply.withLock { $0.error = error } }
                    )
                }
            } onCancel: {
                // Barge-in / stop: no late chunk may play or flip the phase.
                player.cancel()
                speechSink.finish()
            }
            speechSink.finish()
            let spoke = await player.value
            guard !Task.isCancelled else { return }
            let result = reply.withLock { $0 }
            flushLiveReply()
            if let error = result.error {
                fail(error)
                return
            }
            if let last = session.indices.last {
                session[last].content = result.text
                session[last].isStreaming = false
            }
            if toolsEnabled, let call = ToolRunner.extractCall(from: result.text) {
                let output = call.name == "file_read"
                    ? "Error: file_read is unavailable in Voice. Ask the user to attach the file in chat."
                    : await ToolRunner.run(call)
                // Let any spoken preamble finish; the next round's first
                // chunk restarts the playback timeline.
                if spoke { await waitForNativeSpeechEnd() }
                guard !Task.isCancelled else { return }
                session.append(ChatMessage(role: .tool, content: output))
                session.append(ChatMessage(role: .assistant, content: "", isStreaming: true))
                resetLiveReply()
                continue
            }
            if spoke {
                await waitForNativeSpeechEnd()
            } else if speak, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // When LFM3 picks the output mode itself it may answer in
                // text only; never leave a spoken turn silent.
                await speakNativeTextReply(result.text)
            }
            guard !Task.isCancelled else { return }
            pendingTranscript = ""
            liveTranscript = ""
            try? applyConversationSession(forSpeaking: false)
            _ = resumeListeningOrFail()
            return
        }
        fail("The model reached the tool-call limit. Try a shorter request.")
    }

    /// Sentence-boundary detection lives in `SemanticChunker` now —
    /// see Services/Voice/Pipeline/SemanticChunker.swift.

    private func waitForSpeechCompletion() async {
        // 5 minutes is well above any plausible spoken reply (the longest
        // ~2000-token answer at 150wpm is ~10 minutes, but the streaming
        // path means we're only blocking until the queue drains — not
        // generation). The deadline is a safety net against deadlocks.
        let deadline = Date().addingTimeInterval(300)
        // Generation is already done when we get here, so a long stretch
        // with no audio and no engine load means synthesis or playback hung.
        // The 5-minute deadline alone left the user staring at a silent
        // "speaking" orb with the mic closed.
        var lastAudio = Date()
        while !Task.isCancelled
                && voice.isPlaying
                && phase == .speaking
                && Date() < deadline {
            if AudioPlaybackService.shared.isPlaying || voice.isLoadingEngine {
                lastAudio = Date()
            } else if Date().timeIntervalSince(lastAudio) > 15 {
                print("[VoiceConversation] no speech audio for 15 s — giving the mic back")
                voice.stop()
                return
            }
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
            guard phase != .idle, phase != .paused else { return }
            // Recoverable pause, not a failure. The old code parked on
            // `.listening` with the last partial transcript still pending,
            // so the stability net could fire a turn mid-call and start
            // generating + speaking over the phone call.
            turnID &+= 1
            finalizeAssistantTurn(interrupted: true)
            replyTask?.cancel()
            replyTask = nil
            voice.stop()
            AudioPlaybackService.shared.stop()
            assistant.stopGeneration()
            dictation.pauseEngineForTTS()
            clearNativeAudio()
            pendingTranscript = ""
            liveTranscript = ""
            phase = .paused
            SpeechPlaybackCoordinator.shared.bindSessionPhase(.paused)

        case .ended:
            guard phase == .paused else { return }
            let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            // Without `.shouldResume` (e.g. the user took the call) stay
            // paused with history intact; tapping the orb resumes.
            guard options.contains(.shouldResume) else { return }
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
            if phase == .speaking { voice.stop(); AudioPlaybackService.shared.stop() }
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
        AudioPlaybackService.shared.stop()
        assistant.stopGeneration()
        dictation.stop()
        phase = .failed("Audio system was reset. Tap Retry to continue.")
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
}
