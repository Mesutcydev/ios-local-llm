import AVFoundation
import Combine
import Foundation

// MARK: - VoiceService
// Main orchestrator for all text-to-speech operations.
//
// Usage:
//   1. Call load() at app startup (or lazily when first needed).
//   2. Call speak(text:) to read text aloud.
//   3. Call stop() to cancel.
//   4. Observe isPlaying, currentEngineKind, and engineStates for UI.
//
// Engine selection:
//   • If the preferred engine (from AppSettings) is ready → use it.
//   • Otherwise fall back to Apple System Voice (always available).
//
// Chunking: long texts are split via TextChunker and spoken sequentially.

@MainActor
final class VoiceService: ObservableObject {

    // MARK: - Singleton

    static let shared = VoiceService()

    // MARK: - Published state

    @Published private(set) var isPlaying = false
    @Published private(set) var currentEngineKind: VoiceEngineKind = .appleSystem

    /// State per engine — used by VoiceStatusView.
    @Published private(set) var systemState:  VoiceModelState = .ready
    @Published private(set) var kittenState:  VoiceModelState = .unloaded
    @Published private(set) var kokoroState:  VoiceModelState = .unloaded

    // MARK: - Engines

    let systemEngine  = SystemSpeechService()
    let kittenEngine  = KittenTTSService()
    let kokoroEngine  = KokoroTTSService()

    /// All voices the user could currently select — the active engine's
    /// voices plus the always-available system voices, deduplicated by id.
    /// Callers (e.g. persona→voice resolution) look a voice up by id, so
    /// aggregating the reachable engines gives the widest correct set.
    var availableVoices: [VoiceOption] {
        var seen = Set<String>()
        let active = resolvedEngine(for: currentEngineKind).availableVoices
        return (active + systemEngine.availableVoices)
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: - Private

    private var currentTask: Task<Void, Never>?
    private let playbackService = AudioPlaybackService.shared
    private var settings: AppSettings { AppSettings.shared }
    private var downloadObserver: NSObjectProtocol?

    // MARK: - Init / Deinit

    private init() {
        VoiceSettingsStore.shared.beginAvailabilityCheck()
        Task { @MainActor in
            self.validatePersistedSelection()
            if VoiceSettingsStore.shared.selectedEngine != .appleSystem {
                await self.load()
            }
        }
        // Auto-refresh and (optionally) auto-load the preferred engine when
        // its download completes. Users shouldn't have to manually tap "Load
        // Engine" after the model files arrive.
        downloadObserver = NotificationCenter.default.addObserver(
            forName: .hfModelDownloadCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let repoID = note.userInfo?["repoID"] as? String else { return }
            let lower = repoID.lowercased()
            let isVoiceDownload =
                lower.contains("kitten") ||
                lower.contains("kokoro") ||
                lower.contains("tts")
            guard isVoiceDownload else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let preferred = VoiceEngineKind(rawValue: self.settings.voiceEngine) ?? .appleSystem
                if preferred == .kittenTTS && VoiceModelBundleValidator.isKittenTTSAvailable() {
                    self.kittenState = .loading
                    await self.kittenEngine.load()
                    self.kittenState = self.kittenEngine.modelState
                    if self.kittenState == .ready {
                        ToastCenter.shared.success("KittenTTS ready")
                    }
                }
                if preferred == .kokoro && VoiceModelBundleValidator.isKokoroAvailable() {
                    self.kokoroState = .loading
                    await self.kokoroEngine.load()
                    self.kokoroState = self.kokoroEngine.modelState
                    if self.kokoroState == .ready {
                        ToastCenter.shared.success("Kokoro ready (experimental)")
                    }
                }
            }
        }
    }

    deinit {
        if let o = downloadObserver { NotificationCenter.default.removeObserver(o) }
        currentTask?.cancel()
    }

    // MARK: - Load

    /// Loads the preferred engine if it requires a model download.
    /// System voice is always ready and needs no loading.
    func load() async {
        let preferred = VoiceEngineKind(rawValue: settings.voiceEngine) ?? .appleSystem

        switch preferred {
        case .kittenTTS:
            kittenState = .loading
            await kittenEngine.load()
            kittenState = kittenEngine.modelState

        case .kokoro:
            kokoroState = .loading
            await kokoroEngine.load()
            kokoroState = kokoroEngine.modelState

        case .appleSystem:
            break   // always ready
        }

        refreshStates()
        currentEngineKind = resolvedEngine(for: preferred).kind
    }

    /// Disk discovery is synchronous and authoritative. Engine loading is a
    /// separate phase: a Core ML load failure routes audio to Apple for that
    /// session without erasing an installed engine preference.
    private func validatePersistedSelection() {
        let restored = VoiceSettingsStore.shared.selectedEngine
        var available: Set<VoiceEngineKind> = [.appleSystem]
        if VoiceModelBundleValidator.isKittenTTSAvailable() { available.insert(.kittenTTS) }
        if VoiceModelBundleValidator.isKokoroAvailable() { available.insert(.kokoro) }
        print("[VoiceService] installed neural engines discovered=\(available.map(\.rawValue).sorted())")
        VoiceSettingsStore.shared.completeAvailabilityCheck(availableEngines: available)
        if restored != .appleSystem,
           VoiceSettingsStore.shared.selectedEngine == .appleSystem {
            ToastCenter.shared.info(
                "\(restored.shortName) is no longer available",
                detail: "Voice Mode switched to Apple TTS. Download the model again to restore it."
            )
        }
    }

    /// Loads all downloaded engines eagerly.
    func loadAll() async {
        if VoiceModelBundleValidator.isKittenTTSAvailable() {
            kittenState = .loading
            await kittenEngine.load()
            kittenState = kittenEngine.modelState
        }
        if VoiceModelBundleValidator.isKokoroAvailable() {
            kokoroState = .loading
            await kokoroEngine.load()
            kokoroState = kokoroEngine.modelState
        }
        refreshStates()
    }

    /// Selects and validates a specific official Kitten variant without any
    /// Apple-TTS fallback. A success result therefore proves that the card's
    /// own runtime returned non-silent PCM.
    func activateAndTestKittenVariant(_ variant: KittenVariant) async throws {
        stop()
        kittenEngine.unload()
        VoiceSettingsStore.shared.selectKittenVariant(variant)
        settings.voiceEngine = VoiceEngineKind.kittenTTS.rawValue
        kittenState = .loading
        await kittenEngine.load()
        kittenState = kittenEngine.modelState
        guard kittenEngine.isReady else {
            throw VoiceError.engineNotReady("\(kittenEngine.modelState)")
        }
        let voice = kittenEngine.availableVoices.first
            ?? VoiceOption(id: "kitten:expr-voice-2-f", name: "Bella", engineKind: .kittenTTS, locale: "en-US", description: nil)
        let result = try await kittenEngine.synthesize(
            text: "Hello. This voice model is installed and working.",
            voice: voice,
            settings: VoiceSynthesisSettings()
        )
        guard let buffer = result.pcmBuffer, result.duration > 0.25 else {
            throw VoiceError.synthesisFailedWithError("Smoke test returned no playable PCM.")
        }
        currentEngineKind = .kittenTTS
        await playbackService.play(buffer: buffer, volume: 1)
    }

    // MARK: - Speak

    /// Speaks `text` using the user's preferred engine, falling back to system TTS if needed.
    func speak(_ text: String) {
        stop()

        // Audio-session handshake: dictation leaves the session in `.record`
        // and deactivated. Without flipping it back to playback here, the very
        // next AVSpeechSynthesizer.speak() runs silently — the exact "STT and
        // LLM work but no sound" bug in voice-conversation mode.
        prepareSessionForPlayback()

        let synthSettings = VoiceSynthesisSettings(
            speed:  Float(settings.voiceSpeed),
            pitch:  Float(settings.voicePitch),
            volume: Float(settings.voiceVolume)
        )

        // Strip chain-of-thought before chunking. Thinking-mode users
        // can still see the reasoning on screen — `liveReply` in the
        // conversation service is fed the raw stream — but anything
        // routed through `speak()` (analysis panel auto-read, Lens
        // speak-on-final, "read aloud" button, voice preview) is for
        // audio only and must not narrate the model's scratch work.
        let speakable = ReasoningStripper.strip(text)
        let config = TextChunker.Config(
            maxChunkLength: 250,
            summarizeCodeBlocks: !settings.voiceReadCodeBlocks
        )
        let chunks = TextChunker.chunks(from: speakable, config: config)

        SpeechPlaybackCoordinator.shared.beginUtterance(karaokeSeed: speakable)
        isPlaying = true
        streamGeneration &+= 1
        let myGeneration = streamGeneration
        currentTask = Task {
            let preferredKind = VoiceEngineKind(rawValue: self.settings.voiceEngine) ?? .appleSystem
            await self.ensureEngineReadyIfNeeded(for: preferredKind)
            let engine = self.resolvedEngine(for: preferredKind)
            self.currentEngineKind = engine.kind

            let voiceID = self.settings.voiceID
            // Last-resort fallback: a blank VoiceOption lets AVSpeechSynthesizer
            // choose the system default voice rather than silently dropping speech.
            // Upgrade any compact Default Apple voice to Enhanced/Premium so a
            // persisted voiceID from an older build can't keep sounding zombie.
            var voice: VoiceOption = engine.availableVoices.first(where: { $0.id == voiceID })
                ?? engine.availableVoices.first
                ?? self.systemEngine.defaultVoice
                ?? self.systemEngine.availableVoices.first
                ?? VoiceOption(id: "", name: "Default",
                               engineKind: .appleSystem,
                               locale: Locale.current.identifier,
                               description: nil)
            if engine.kind == .appleSystem {
                voice = self.systemEngine.upgradedVoice(for: voice)
                if voice.id != voiceID, !voice.id.isEmpty {
                    self.settings.voiceID = voice.id
                }
            }
            defer {
                Task { @MainActor in
                    if self.streamGeneration == myGeneration {
                        self.isPlaying = false
                    }
                }
            }

            // Track whether we've fallen back to system already so we only
            // warn the user once per speak() call.
            var fellBack = false
            var activeEngine: any LocalVoiceEngine = engine
            var activeVoice: VoiceOption = voice

            // Pipeline: synthesize chunk N+1 while chunk N plays. Cuts the
            // Kitten/Kokoro "gap between sentences" lag roughly in half.
            var pending: Task<VoiceSynthesisResult, Error>?
            var pendingIndex = 0

            func synthesizeChunk(_ index: Int, engine: any LocalVoiceEngine, voice: VoiceOption) -> Task<VoiceSynthesisResult, Error> {
                let text = chunks[index]
                return Task {
                    try await engine.synthesize(text: text, voice: voice, settings: synthSettings)
                }
            }

            if !chunks.isEmpty {
                pending = synthesizeChunk(0, engine: activeEngine, voice: activeVoice)
                pendingIndex = 0
            }

            while pendingIndex < chunks.count {
                guard !Task.isCancelled else { break }
                let currentIndex = pendingIndex
                do {
                    guard let currentSynthesis = pending else { break }
                    let result = try await currentSynthesis.value
                    // Kick off the next synthesis before we block on playback.
                    let nextIndex = currentIndex + 1
                    if nextIndex < chunks.count {
                        pending = synthesizeChunk(nextIndex, engine: activeEngine, voice: activeVoice)
                        pendingIndex = nextIndex
                    } else {
                        pending = nil
                        pendingIndex = chunks.count
                    }
                    if result.pcmBuffer != nil {
                        await self.playRegisteredChunk(
                            text: chunks[currentIndex],
                            result: result,
                            volume: synthSettings.volume,
                            preferredKind: preferredKind,
                            isFallback: fellBack
                        )
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // KittenTTS/Kokoro can fail on some inputs — fall back
                    // to AVSpeechSynthesizer for the rest of the utterance.
                    print("[VoiceService] synthesis error: \(error)")
                    if !fellBack {
                        fellBack = true
                        await MainActor.run { self.playbackService.stop() }
                        await MainActor.run {
                            ToastCenter.shared.info(
                                "Switched to System Voice",
                                detail: "On-device engine produced no audio."
                            )
                        }
                    }
                    activeEngine = systemEngine
                    activeVoice = systemEngine.defaultVoice ?? activeVoice
                    currentEngineKind = .appleSystem
                    // Re-synthesize the failed chunk on system, then continue
                    // the pipeline from there.
                    pending = synthesizeChunk(currentIndex, engine: activeEngine, voice: activeVoice)
                    pendingIndex = currentIndex
                    do {
                        guard let fallbackSynthesis = pending else { break }
                        let result = try await fallbackSynthesis.value
                        let nextIndex = currentIndex + 1
                        if nextIndex < chunks.count {
                            pending = synthesizeChunk(nextIndex, engine: activeEngine, voice: activeVoice)
                            pendingIndex = nextIndex
                        } else {
                            pending = nil
                            pendingIndex = chunks.count
                        }
                        if result.pcmBuffer != nil {
                            await self.playRegisteredChunk(
                                text: chunks[currentIndex],
                                result: result,
                                volume: synthSettings.volume,
                                preferredKind: preferredKind,
                                isFallback: true
                            )
                        }
                    } catch {
                        break
                    }
                }
            }
            // Continuous schedule returns before consumption — drain the player
            // so isPlaying / turn-taking stay aligned with audible audio.
            await self.playbackService.waitUntilQueueDrained()
        }
    }

    // MARK: - Stop

    /// Monotonic counter bumped each time a new speak/speakStream task starts
    /// (or stop() runs). Each task captures the generation at startup so its
    /// `defer { isPlaying = false }` block only mutates state when it's still
    /// the live task. Without this, the cancelled prior task's defer fires
    /// asynchronously on the MainActor *after* the new task has already set
    /// isPlaying = true, races-clobbers the flag, and
    /// `VoiceConversationService.waitForSpeechCompletion()` exits immediately
    /// — that's the "voice mode never speaks back" symptom even though the
    /// streaming task is happily synthesising chunks.
    private var streamGeneration: UInt64 = 0

    func stop() {
        streamGeneration &+= 1
        currentTask?.cancel()
        currentTask = nil
        activeStreamSession?.stop()
        activeStreamSession = nil
        playbackService.stop()
        systemEngine.stop()
        isPlaying = false
    }

    // MARK: - Streaming speak
    //
    // Consumes utterances from an `AudioQueue` while the LLM is still
    // generating, so the user hears the first sentence the moment it
    // finishes instead of waiting for the full reply. The queue is fed
    // by the conversation loop's `onToken` callback (via SemanticChunker
    // → LanguageDetector → enqueue); this method just drains it through
    // the same synthesise + play pipeline `speak()` uses.

    private weak var activeStreamSession: AudioQueue?

    /// Drains `queue` until it's marked finished, synthesising each
    /// utterance with the user's preferred engine (falling back to
    /// system on the same per-chunk error as `speak()`). The audio
    /// session is configured once up front; the streamer does NOT
    /// call `stop()` first, so it can run alongside an ongoing
    /// `speak()` only after that one completes.
    func speakStream(_ queue: AudioQueue) {
        // Cancel prior playback without wiping karaoke text the conversation
        // service may have already seeded for this turn.
        streamGeneration &+= 1
        currentTask?.cancel()
        currentTask = nil
        activeStreamSession?.stop()
        activeStreamSession = nil
        playbackService.stop()
        systemEngine.stop()
        isPlaying = false
        SpeechPlaybackCoordinator.shared.cancelActivePlayback(markInterrupted: false)

        prepareSessionForPlayback()

        let synthSettings = VoiceSynthesisSettings(
            speed:  Float(settings.voiceSpeed),
            pitch:  Float(settings.voicePitch),
            volume: Float(settings.voiceVolume)
        )

        let subChunkConfig = TextChunker.Config(
            maxChunkLength: 250,
            summarizeCodeBlocks: !settings.voiceReadCodeBlocks
        )

        activeStreamSession = queue
        isPlaying = true
        streamGeneration &+= 1
        let myGeneration = streamGeneration
        currentTask = Task { [weak self] in
            guard let self else { return }
            let preferredEngineKind = VoiceEngineKind(rawValue: self.settings.voiceEngine) ?? .appleSystem
            await self.ensureEngineReadyIfNeeded(for: preferredEngineKind)
            let preferredEngine = self.resolvedEngine(for: preferredEngineKind)
            self.currentEngineKind = preferredEngine.kind

            let voiceID = self.settings.voiceID
            var preferredVoice: VoiceOption = preferredEngine.availableVoices.first(where: { $0.id == voiceID })
                ?? preferredEngine.availableVoices.first
                ?? self.systemEngine.defaultVoice
                ?? self.systemEngine.availableVoices.first
                ?? VoiceOption(id: "", name: "Default",
                               engineKind: .appleSystem,
                               locale: Locale.current.identifier,
                               description: nil)
            if preferredEngine.kind == .appleSystem {
                preferredVoice = self.systemEngine.upgradedVoice(for: preferredVoice)
                if preferredVoice.id != voiceID, !preferredVoice.id.isEmpty {
                    self.settings.voiceID = preferredVoice.id
                }
            }
            defer {
                // Stale-defer guard: only clear isPlaying when this task is
                // still the live one. A subsequent speak/speakStream bumps
                // streamGeneration before our defer runs; clobbering the
                // flag then would mute the new turn's TTS even though it's
                // mid-synthesis.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.streamGeneration == myGeneration {
                        self.isPlaying = false
                    }
                }
            }

            // Per-utterance "we already fell back to system once" latch —
            // suppresses repeated toast spam if every chunk fails on the
            // preferred engine. Language-driven routing below is separate
            // and runs every chunk.
            //
            // STICKINESS: once `fellBackHard` is true we route ALL
            // remaining chunks of this utterance through the system
            // engine. Earlier builds re-tried the preferred (KittenTTS)
            // engine on each chunk after a per-chunk error, so a partial
            // Kitten success+throw pattern produced an alternating
            // "zombie → clean → zombie" cadence between sentences. The
            // user could see the "Switched to System Voice" toast and
            // STILL hear distorted audio on the next chunk because Kitten
            // kept being retried. Latching the engine swap for the rest
            // of the stream gives the user a single clean voice from the
            // moment the failure is detected.
            var fellBackHard = false

            while !Task.isCancelled {
                guard let entry = await queue.next() else { break }
                // Resolve engine + voice for THIS chunk based on its
                // detected language. nil language → use preferred.
                // Mismatched language → either the preferred engine has a
                // matching voice (use it) or we route through system.
                // An `engineHint` on the utterance overrides the
                // language-based router (used by future callers that
                // know exactly which engine they want for one chunk).
                //
                // After a hard fallback, ignore the router entirely —
                // every remaining chunk renders through the system
                // engine with the best AVSpeech voice for the language.
                let (chunkEngine, chunkVoice): (any LocalVoiceEngine, VoiceOption)
                if fellBackHard {
                    let voice = self.resolveSystemVoice(
                        forLanguage: entry.language,
                        fallback: preferredVoice
                    )
                    chunkEngine = self.systemEngine
                    chunkVoice = voice
                } else {
                    (chunkEngine, chunkVoice) = self.resolveEngineAndVoice(
                        preferredEngine: preferredEngine,
                        preferredVoice: preferredVoice,
                        language: entry.language,
                        engineHint: entry.engineHint
                    )
                }
                await MainActor.run { self.currentEngineKind = chunkEngine.kind }

                // The caller hands us sentence-sized chunks already, but a
                // multi-sentence final flush would otherwise stream as one
                // 600-char utterance — run it through TextChunker so long
                // text still respects engine limits.
                let subChunks = TextChunker.chunks(from: entry.text, config: subChunkConfig)
                for sub in subChunks {
                    if Task.isCancelled { break }
                    var activeEngine: any LocalVoiceEngine = chunkEngine
                    var activeVoice: VoiceOption = chunkVoice
                    do {
                        let result = try await activeEngine.synthesize(
                            text: sub,
                            voice: activeVoice,
                            settings: synthSettings
                        )
                        if result.pcmBuffer != nil {
                            await self.playRegisteredChunk(
                                text: sub,
                                result: result,
                                volume: synthSettings.volume,
                                preferredKind: preferredEngineKind,
                                isFallback: fellBackHard
                            )
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        // Synthesis error on the resolved engine — fall back
                        // to system TTS. The fallback is now STICKY for the
                        // rest of the utterance (see fellBackHard comment in
                        // the outer scope): once a chunk fails on the
                        // preferred engine, all subsequent chunks go through
                        // system. Without this, KittenTTS would be retried
                        // on the next chunk and could produce another
                        // garbled "zombie voice" burst between clean system
                        // utterances.
                        print("[VoiceService] stream synthesis error: \(error)")
                        if !fellBackHard {
                            fellBackHard = true
                            // Stop any in-flight PCM playback so a half-
                            // played zombie buffer doesn't keep playing
                            // through the system voice's first words.
                            // playbackService is MainActor-isolated, hence
                            // the hop.
                            await MainActor.run { self.playbackService.stop() }
                            await MainActor.run {
                                ToastCenter.shared.info(
                                    "Switched to System Voice",
                                    detail: "On-device engine produced no audio."
                                )
                            }
                        }
                        activeEngine = self.systemEngine
                        activeVoice = self.resolveSystemVoice(
                            forLanguage: entry.language,
                            fallback: self.systemEngine.defaultVoice ?? activeVoice
                        )
                        await MainActor.run { self.currentEngineKind = .appleSystem }
                        do {
                            let result = try await activeEngine.synthesize(
                                text: sub, voice: activeVoice, settings: synthSettings)
                            if result.pcmBuffer != nil {
                                await self.playRegisteredChunk(
                                    text: sub,
                                    result: result,
                                    volume: synthSettings.volume,
                                    preferredKind: preferredEngineKind,
                                    isFallback: true
                                )
                            }
                        } catch {
                            return
                        }
                    }
                }
            }
            await self.playbackService.waitUntilQueueDrained()
        }
    }

    /// Schedules PCM first (the player clock keeps running through synthesis
    /// underruns), then anchors the chunk's karaoke timeline at the REAL
    /// playhead position the buffer was placed at.
    private func playRegisteredChunk(
        text: String,
        result: VoiceSynthesisResult,
        volume: Float,
        preferredKind: VoiceEngineKind,
        isFallback: Bool
    ) async {
        guard let buffer = result.pcmBuffer else { return }
        let coordinator = SpeechPlaybackCoordinator.shared
        coordinator.notePreferredEngine(
            preferredKind,
            isFallback: isFallback || result.engineKind != preferredKind
        )
        // Continuous player timeline: schedule without stop/reset between
        // chunks. Registration happens right after with the true placement,
        // so karaoke can't leap ahead when the clock outruns the naive
        // contiguous timeline during synthesis gaps.
        let startSample = await playbackService.schedule(buffer: buffer, volume: volume)
        let renderRate = playbackService.renderSampleRate
        let timelineOffset = Double(startSample) / max(1, renderRate)
        await coordinator.registerChunk(
            text: text,
            buffer: buffer,
            engineKind: result.engineKind,
            engineAlignment: result.alignment,
            synthesisMetadata: result.synthesisMetadata,
            timelineOffsetOverride: timelineOffset,
            renderSampleRate: renderRate
        )
        // Back-pressure at ~2 queued buffers.
        while playbackService.queuedBufferCount > 2, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    // MARK: - Engine resolution

    /// Returns the preferred engine if ready, otherwise falls back to
    /// system. The readiness gate covers both "engine hasn't been
    /// loaded yet" and "engine load failed its self-check" — in the
    /// latter case the engine's `modelState` is `.failed(...)` and the
    /// VoiceModelPickerView surfaces the message so the user can either
    /// retry or pick a different engine. Until they do, every speak()
    /// transparently routes through System Voice.
    private func resolvedEngine(for kind: VoiceEngineKind) -> any LocalVoiceEngine {
        switch kind {
        case .kittenTTS:
            return kittenEngine.isReady ? kittenEngine : systemEngine
        case .kokoro:
            return kokoroEngine.isReady ? kokoroEngine : systemEngine
        case .appleSystem:
            return systemEngine
        }
    }

    // MARK: - Per-chunk language routing
    //
    // When a streaming chunk arrives with a detected language tag, the
    // user's preferred voice may or may not match. Three outcomes:
    //
    //   1. Tag missing or matches the preferred voice's locale prefix
    //      → use preferred verbatim (cheap path, the common case).
    //   2. Tag mismatches and the preferred engine has a voice for
    //      that language → swap voice within the preferred engine.
    //      KittenTTS currently ships English voices only, so this
    //      branch fires almost exclusively for AVSpeech.
    //   3. Tag mismatches and the preferred engine has no matching
    //      voice → route THIS chunk through the system engine with
    //      the best AVSpeech voice for the language. The next chunk
    //      starts fresh from preferred again, so a mixed-language
    //      reply alternates engines cleanly per sentence.

    /// Resolves `(engine, voice)` for a single chunk. Pure (depends
    /// only on the supplied preferred-pair, `language`, and the
    /// optional engine hint); safe to call from the streaming task
    /// on MainActor.
    ///
    /// `engineHint` is a forced override — when set, that engine is
    /// used unconditionally and the voice is the best-available for
    /// the language within that engine's voices (falling back to
    /// the engine's default voice when no language match). Used by
    /// future callers that need a specific engine per chunk
    /// regardless of routing.
    private func resolveEngineAndVoice(
        preferredEngine: any LocalVoiceEngine,
        preferredVoice: VoiceOption,
        language: String?,
        engineHint: VoiceEngineKind? = nil
    ) -> (any LocalVoiceEngine, VoiceOption) {
        if let hint = engineHint {
            let hinted = resolvedEngine(for: hint)
            let voice: VoiceOption
            if let lang = language,
               let match = bestVoice(in: hinted.availableVoices, forLanguage: lang) {
                voice = match
            } else {
                voice = hinted.availableVoices.first
                    ?? systemEngine.defaultVoice
                    ?? preferredVoice
            }
            return (hinted, voice)
        }
        guard let lang = language, !lang.isEmpty else {
            return (preferredEngine, preferredVoice)
        }
        if voiceMatchesLanguage(preferredVoice, language: lang) {
            return (preferredEngine, preferredVoice)
        }
        // Preferred engine, different voice — best quality available
        // for the language. Skip when the preferred engine has zero
        // voices for the language to avoid degrading nano-style
        // neural engines that don't have the locale at all.
        if let match = bestVoice(in: preferredEngine.availableVoices, forLanguage: lang) {
            return (preferredEngine, match)
        }
        // Preferred engine doesn't speak this language — route the
        // chunk through system TTS, which has the broadest locale
        // coverage on every iOS device.
        let systemVoice = resolveSystemVoice(forLanguage: lang, fallback: preferredVoice)
        return (systemEngine, systemVoice)
    }

    /// Best AVSpeech voice for a language. Used both for per-chunk
    /// routing and as a fallback path when the preferred engine
    /// fails synthesis on a non-English chunk.
    ///
    /// If the requested language has NO matching voice on this
    /// device (a user with no Turkish voice installed will hit this
    /// path on every Turkish chunk), the fallback voice gets used
    /// instead — that's the path that produces "English voice
    /// reading Turkish phonemes" → unintelligible. Surface a one-
    /// shot toast for each missing-language so the user can install
    /// the voice rather than silently degrading.
    fileprivate func resolveSystemVoice(forLanguage language: String?,
                                         fallback: VoiceOption) -> VoiceOption {
        guard let lang = language, !lang.isEmpty else { return fallback }
        if let match = bestVoice(in: systemEngine.availableVoices, forLanguage: lang) {
            return match
        }
        warnAboutMissingVoice(forLanguage: lang)
        return fallback
    }

    /// Languages we've already warned about in this app launch.
    /// Toast fires at most once per language per session to avoid
    /// spam — the user installs the voice once and never has to
    /// see the prompt again.
    private var warnedMissingVoiceLanguages: Set<String> = []

    private func warnAboutMissingVoice(forLanguage language: String) {
        let prefix = (language.split(separator: "-").first.map(String.init) ?? language).lowercased()
        guard warnedMissingVoiceLanguages.insert(prefix).inserted else { return }
        let displayLanguage = Locale.current
            .localizedString(forLanguageCode: prefix)?
            .capitalized ?? prefix.uppercased()
        ToastCenter.shared.info(
            "\(displayLanguage) voice not installed",
            detail: "Open Settings → Accessibility → Spoken Content → Voices → \(displayLanguage) to install. Falling back to your current voice for now."
        )
        print("[VoiceService] No installed voice for language '\(language)' — falling back to '\(language == prefix ? prefix : language)'-incapable preferred voice. Chunks may sound wrong.")
    }

    private func voiceMatchesLanguage(_ voice: VoiceOption, language: String) -> Bool {
        // Compare on the two-letter language code only. AVSpeech
        // voices identify themselves as `en-US`, `en-GB`, etc.; the
        // detector returns `en-US` for any en-* hypothesis. Matching
        // just the prefix lets a user with an en-AU preferred voice
        // continue using it on en-US text without ping-ponging.
        let voicePrefix = voice.locale.split(separator: "-").first.map(String.init) ?? voice.locale
        let langPrefix  = language.split(separator: "-").first.map(String.init) ?? language
        return voicePrefix.lowercased() == langPrefix.lowercased()
    }

    private func bestVoice(in voices: [VoiceOption], forLanguage language: String) -> VoiceOption? {
        let langPrefix = (language.split(separator: "-").first.map(String.init) ?? language).lowercased()
        let candidates = voices.filter {
            let prefix = $0.locale.split(separator: "-").first.map(String.init) ?? $0.locale
            return prefix.lowercased() == langPrefix
        }
        guard !candidates.isEmpty else { return nil }
        // Prefer Premium/Enhanced over compact Default within the language.
        // SystemSpeechService sorts availableVoices that way already, but
        // language-filtered subsets from mixed lists may not — and a
        // Default candidate is the zombie-voice path.
        if let hq = candidates.first(where: { systemEngine.isHighQuality($0) }) {
            return hq
        }
        return candidates.first
    }

    // MARK: - Available voices for picker

    /// Returns voices available from the currently preferred engine.
    var availableVoicesForCurrentEngine: [VoiceOption] {
        let kind = VoiceEngineKind(rawValue: settings.voiceEngine) ?? .appleSystem
        let engine = resolvedEngine(for: kind)
        return engine.availableVoices
    }

    // MARK: - Audio session

    /// Reactivate the shared AVAudioSession in a playback-capable category.
    /// SpeechDictationService.cleanup() now deactivates the session before
    /// returning, so this call is what brings it back for TTS.
    ///
    /// Use the exact same category + options as SystemSpeechService so the
    /// engine's own configurePlaybackSession() call is a no-op rather than a
    /// rapid second category switch — back-to-back swaps in voice-conversation
    /// mode used to leave AVSpeechSynthesizer routed to a stale audio unit
    /// and the utterance played silently (the "STT and LLM work but no
    /// audio" symptom).
    private func prepareSessionForPlayback() {
        let session = AVAudioSession.sharedInstance()

        // Only leave `.playAndRecord` alone while the conversation is
        // actively listening/thinking (mic must stay open). During
        // `.speaking` we deliberately switch to `.playback` — the old
        // `phase != .idle` check blocked that and left Apple TTS on the
        // full-duplex zombie path. `.failed` must also allow cleanup.
        if session.category == .playAndRecord,
           VoiceConversationService.shared.isHoldingRecordSession {
            return
        }

        // Plain TTS path. Use `.playback`, NOT `.playAndRecord`.
        // Prefer A2DP on Bluetooth headsets (high-quality stereo) over
        // any residual HFP route from a prior conversation session.
        // `.playback` already uses A2DP. `.allowBluetoothA2DP` is for
        // input-capable categories; combining it with `.playback` can leave a
        // failed transition sitting on the previous HFP route.
        let desiredOptions: AVAudioSession.CategoryOptions = [.duckOthers]
        let alreadyConfigured = session.category == .playback
            && session.mode == .spokenAudio
            && session.categoryOptions == desiredOptions
        do {
            if !alreadyConfigured {
                if session.category == .playAndRecord || session.category == .record {
                    try? session.setActive(false, options: [])
                }
                try session.setCategory(.playback, mode: .spokenAudio, options: desiredOptions)
            }
            // The category can still match after voice-mode teardown even
            // though the session is inactive. Always reactivate it.
            try session.setActive(true, options: [])
        } catch {
            print("[VoiceService] Failed to set playback session: \(error)")
        }
    }

    // MARK: - Lazy neural engine load

    /// Voice mode can be entered directly from cold app launch, with a
    /// persisted KittenTTS/Kokoro preference but without the user ever
    /// visiting Voice Settings and tapping "Load engine". In that case the
    /// old code would quietly route everything through System Voice because
    /// `resolvedEngine(for:)` only returned the neural engine AFTER it had
    /// been loaded once. Load on first use so a valid bundled/downloaded
    /// neural model actually speaks in voice mode.
    private func ensureEngineReadyIfNeeded(for kind: VoiceEngineKind) async {
        switch kind {
        case .appleSystem:
            return

        case .kittenTTS:
            guard !kittenEngine.isReady, kittenState != .loading else { return }
            guard VoiceModelBundleValidator.isKittenTTSAvailable() else {
                refreshStates()
                return
            }
            kittenState = .loading
            await kittenEngine.load()
            kittenState = kittenEngine.modelState

        case .kokoro:
            guard !kokoroEngine.isReady, kokoroState != .loading else { return }
            guard VoiceModelBundleValidator.isKokoroAvailable() else {
                refreshStates()
                return
            }
            kokoroState = .loading
            await kokoroEngine.load()
            kokoroState = kokoroEngine.modelState
        }
        refreshStates()
    }

    // MARK: - State sync

    private func refreshStates() {
        systemState = systemEngine.modelState
        kittenState = kittenEngine.modelState
        kokoroState = kokoroEngine.modelState
    }

    // MARK: - Unload

    func unloadAll() {
        stop()
        kittenEngine.unload()
        kokoroEngine.unload()
        refreshStates()
    }
}

// MARK: - StreamingSpeechSession (retired)
//
// The producer/consumer queue that used to live here now lives in
// `Services/Voice/Pipeline/AudioQueue.swift`. The rename gives Lens
// (session 3) an independent queue instance per surface and makes
// the @Published state available for the status pill UI. The shape
// is otherwise identical — same suspension semantics, same
// synchronous `stop`, same idempotent terminal states.
