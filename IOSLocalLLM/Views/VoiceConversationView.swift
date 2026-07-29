import SwiftUI
import AVFoundation

// MARK: - VoiceConversationView
// Hands-free conversation surface: audio-reactive orb, karaoke transcript,
// and a compact control dock. Playback metering and word timing come from
// SpeechPlaybackCoordinator — never simulated amplitude.

struct VoiceConversationView: View {
    @StateObject private var conv = VoiceConversationService.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var loc = LocalizationService.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    /// Do not observe the full coordinator — its snapshot/karaokeText churn
    /// rebuilds this ScrollView and hitch the orb. Narrow models only.
    /// Karaoke text is mirrored via onReceive — never observe spokenUTF16End
    /// from this view (that was the orb flutter source).
    private let playbackCoord = SpeechPlaybackCoordinator.shared
    @ObservedObject private var voiceControls = SpeechPlaybackCoordinator.shared.controls
    @ObservedObject private var voiceSettings = VoiceSettingsStore.shared
    @ObservedObject private var routeManager = VoiceAudioSessionManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showModelPicker = false
    @State private var showVoiceSettings = false
    @State private var testTTSInFlight = false
    @State private var isTranscriptExpanded = false
    @State private var interruptFlash = false
    @State private var confirmEnd = false
    @State private var karaokeText: String = ""
    #if DEBUG
    @State private var showVoiceValidation = false
    #endif

    @AppStorage("voiceAnswerEnabled") private var voiceAnswerEnabled: Bool = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                backdrop.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        topBar
                        identityRows
                        statusRow
                        VoiceOrbContainer(
                            orb: SpeechPlaybackCoordinator.shared.orb,
                            reduceMotion: reduceMotion,
                            onTap: {
                                Task { _ = await conv.start() }
                                HapticManager.impact(.medium)
                            },
                            onInterrupt: { interruptNow() },
                            flash: interruptFlash
                        )
                        VoiceStatusLabel(
                            phase: uiPhase,
                            detail: fallbackDetail
                        )
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["VOICE_TIMING_DEBUG"] == "1"
                            || showVoiceValidation {
                            timingDebugOverlay
                        }
                        #endif
                        transcriptArea
                        if case .failed(let msg) = conv.phase {
                            failureBanner(msg)
                        }
                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .frame(minHeight: proxy.size.height - 100)
                }
                .safeAreaInset(edge: .bottom) {
                    controlDock
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                        .padding(.top, 8)
                        .background(.ultraThinMaterial.opacity(0.92))
                }
            }
        }
        .task {
            _ = await conv.start()
            syncMute()
            karaokeText = SpeechPlaybackCoordinator.shared.karaoke.text
        }
        .onReceive(SpeechPlaybackCoordinator.shared.karaoke.$text) { karaokeText = $0 }
        .onDisappear {
            conv.stop()
            playbackCoord.reset()
        }
        .onChange(of: voiceAnswerEnabled) { _, enabled in
            playbackCoord.setMuted(!enabled)
            if !enabled && conv.phase == .speaking {
                // Mute volume only — do not destroy the in-flight transcript.
                playbackCoord.setMuted(true)
            }
        }
        .onChange(of: conv.phase) { oldPhase, newPhase in
            // Service already binds thinking/speaking/listening. Only sync
            // idle/failed/edge cases here — never downgrade `.speaking` to
            // `.preparingSpeech` because `voice.isPlaying` is still false on
            // the first frame (that gated glass/output reactivity off for the
            // whole reply).
            let mapped = mapPhase(newPhase)
            if shouldViewBindPhase(mapped, servicePhase: newPhase) {
                playbackCoord.bindSessionPhase(mapped)
            }
            announcePhase(mapped)
            if newPhase == .speaking, oldPhase != .speaking {
                HapticManager.impact(.light)
            }
        }
        .onChange(of: voice.isPlaying) { _, playing in
            // Upgrade preparing → speaking once audio actually starts.
            if playing, conv.phase == .speaking,
               playbackCoord.orb.phase == .preparingSpeech {
                playbackCoord.bindSessionPhase(.speaking)
            }
        }
        .sheet(isPresented: $showModelPicker) {
            VoiceModelPickerSheet()
        }
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsView()
        }
        .sheet(isPresented: $isTranscriptExpanded) {
            expandedTranscriptSheet
        }
        #if DEBUG
        .sheet(isPresented: $showVoiceValidation) {
            VoiceValidationView()
        }
        #endif
        .confirmationDialog(loc.t("end"), isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(loc.t("end"), role: .destructive) {
                conv.stop()
                dismiss()
                HapticManager.impact(.medium)
            }
            Button(loc.t("Cancel"), role: .cancel) {}
        } message: {
            Text(loc.t("End conversation"))
        }
        .preferredColorScheme(.light)
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        LinearGradient(
            colors: [
                T.bg,
                T.bg,
                orbAccent.opacity(0.07)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            conversationModelStrip
            Spacer(minLength: 8)
            #if DEBUG
            iconButton(systemImage: "waveform.badge.magnifyingglass",
                       label: "Voice validation") {
                showVoiceValidation = true
            }
            #endif
            iconButton(systemImage: "slider.horizontal.3",
                       label: loc.t("voice settings")) {
                showVoiceSettings = true
                HapticManager.impact(.light)
            }
        }
    }

    /// Conversation LLM only — never shows Kitten/Kokoro/Apple TTS names.
    private var conversationModelStrip: some View {
        Menu {
            modelStripMenuContent
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(assistantStatusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: assistantStatusColor.opacity(0.5), radius: 3)
                Text("Conversation")
                    .font(T.mono(9, .semibold))
                    .tracking(0.4)
                    .foregroundColor(T.ink3)
                Text("·")
                    .font(T.mono(10))
                    .foregroundColor(T.ink3.opacity(0.5))
                Text(assistant.activeModel.displayName)
                    .font(T.mono(11.5, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 160, alignment: .leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(T.ink3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .kGlassCapsule(fallbackFill: T.surface)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .accessibilityLabel("Conversation model: \(assistant.activeModel.displayName)")
    }

    /// Explicit LLM vs TTS identity so Ternary Bonsai is never mistaken for a voice.
    private var identityRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Conversation model")
                    .font(T.mono(9, .semibold))
                    .foregroundStyle(T.ink3)
                Text(assistant.activeModel.displayName)
                    .font(T.mono(10.5, .semibold))
                    .foregroundStyle(T.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("Voice")
                    .font(T.mono(9, .semibold))
                    .foregroundStyle(T.ink3)
                Text(activeVoiceLabel)
                    .font(T.mono(10.5, .semibold))
                    .foregroundStyle(T.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Conversation model \(assistant.activeModel.displayName). Voice \(activeVoiceLabel)"
        )
    }

    @ViewBuilder
    private var modelStripMenuContent: some View {
        let activeOverride = conv.voiceModelID
        let presets = AssistantModelCatalog.presets
        let downloaded = voiceTabDownloadedLLMs()
        let currentLiveID = assistant.activeModel.id

        Section(loc.t("default")) {
            Button {
                HapticManager.impact(.light)
                Task { await conv.setVoiceModel(nil) }
            } label: {
                if activeOverride == nil {
                    Label(loc.t("match chat tab"), systemImage: "checkmark")
                } else {
                    Text(loc.t("match chat tab"))
                }
            }
        }

        Section(loc.t("presets")) {
            ForEach(presets, id: \.id) { preset in
                Button {
                    HapticManager.impact(.light)
                    Task { await conv.setVoiceModel(preset.id) }
                } label: {
                    if currentLiveID == preset.id {
                        Label(preset.displayName, systemImage: "checkmark")
                    } else {
                        Text(preset.displayName)
                    }
                }
            }
        }

        if !downloaded.isEmpty {
            Section(loc.t("downloaded")) {
                ForEach(downloaded, id: \.id) { model in
                    let voiceID = LocalModelRegistry.assistantSelectionID(
                        for: model.id,
                        origin: LocalModelRegistry.origin(for: model)
                    )
                    Button {
                        HapticManager.impact(.light)
                        Task { await conv.setVoiceModel(voiceID) }
                    } label: {
                        if currentLiveID == voiceID || currentLiveID == model.id {
                            Label(model.displayName, systemImage: "checkmark")
                        } else {
                            Text(model.displayName)
                        }
                    }
                }
            }
        }

        Divider()

        Button {
            showModelPicker = true
        } label: {
            Label(loc.t("Browse models…"), systemImage: "ellipsis.circle")
        }
    }

    private func voiceTabDownloadedLLMs() -> [DownloadableModel] {
        let presetIDs = Set(AssistantModelCatalog.presets.map(\.repoID))
        var seen = Set<String>()
        return center.models.filter { m in
            guard m.isReady, !m.isRequired, m.category == .assistant else { return false }
            guard !presetIDs.contains(m.id) else { return false }
            return seen.insert(m.id).inserted
        }
    }

    private var assistantStatusColor: Color {
        switch assistant.state {
        case .ready, .generating: return T.good
        case .loading:            return T.warn
        case .failed:             return T.bad
        case .unloaded:           return T.ink3
        }
    }

    private func iconButton(systemImage: String,
                             label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(T.ink2)
                .frame(width: 44, height: 44)
                .kClearGlass(in: Circle(), fallbackFill: T.surface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - Status row (TTS readiness)

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                readinessChip
                engineChip
                if voiceControls.isFallbackEngine {
                    fallbackChip
                }
                Spacer(minLength: 0)
                testAudioButton
            }

            HStack(spacing: 8) {
                VoiceRouteControl(sessionManager: routeManager)
                Spacer(minLength: 0)
                if voice.isPlaying {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(T.good)
                            .frame(width: 6, height: 6)
                        Text("Playing")
                            .font(T.mono(9, .semibold))
                            .foregroundStyle(T.good)
                    }
                    .accessibilityLabel("Audio playing")
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: voice.isPlaying)
        .animation(.easeInOut(duration: 0.2), value: routeManager.route.uid)
    }

    #if DEBUG
    private var timingDebugOverlay: some View {
        let snap = playbackCoord.snapshot
        let perf = VoicePerformanceMonitor.shared.snapshot
        let audio = AudioPlaybackSnapshotStore.shared.load()
        let session = AVAudioSession.sharedInstance()
        return VStack(alignment: .leading, spacing: 2) {
            Text("Timing: \(snap.timingSource?.diagnosticLabel ?? "—")")
            Text(String(format: "Playback UI: %.2f / %.2f s", snap.currentTime, snap.duration))
            Text(String(
                format: "Audio clock: sample %lld / %lld · sr %.0f · gen %llu",
                audio.currentPlayerSample,
                audio.scheduledSampleCount,
                audio.sampleRate,
                audio.generation
            ))
            Text(String(
                format: "Latency: out %.1f ms · io %.1f ms · total %.1f ms",
                session.outputLatency * 1000,
                session.ioBufferDuration * 1000,
                audio.outputPresentationLatency * 1000
            ))
            Text(String(format: "RMS %.2f · peak %.2f · underruns %llu",
                         audio.outputRMS, audio.outputPeak, audio.underrunCount))
            Text("Active phrase: \(SpeechPlaybackCoordinator.shared.karaoke.activePhraseID?.uuidString.prefix(8) ?? "—")")
            if let detail = snap.alignmentDetail {
                Text(detail)
            }
            Text(String(format: "1st audio: %.0f ms · 1st highlight: %.0f ms",
                         perf.firstAudioLatencyMs, perf.firstHighlightLatencyMs))
            Text(String(format: "Frame avg/max: %.1f / %.1f ms · drops: %d",
                         perf.averageFrameWorkMs, perf.maximumFrameWorkMs, perf.droppedFrames))
            Text("Rebuilds/s: \(perf.transcriptRebuildsPerSecond) · scrolls/s: \(perf.autoScrollsPerSecond)")
            Text("Mode: \(perf.renderingMode.rawValue) · interrupt: \(String(format: "%.0f", perf.interruptLatencyMs)) ms")
            Text("Route: \(routeManager.route.displayName)")
            Text("LLM: \(assistant.activeModel.displayName)")
            Text("TTS: \(voiceSettings.selectedEngine.shortName)")
        }
        .font(T.mono(9))
        .foregroundStyle(T.ink3)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(T.surface.opacity(0.9)))
        .accessibilityHidden(true)
    }
    #endif

    private var readinessChip: some View {
        let label: String = {
            switch voiceSettings.availabilityState {
            case .loading: return "Loading"
            case .failed: return "Unavailable"
            case .ready:
                if voiceControls.isFallbackEngine { return "Fallback active" }
                return engineReady ? "Ready" : "Loading"
            }
        }()
        return chip(label, color: engineReady ? T.good : T.warn)
    }

    private var engineReady: Bool {
        switch voiceSettings.selectedEngine {
        case .appleSystem: return true
        case .kittenTTS: return voice.kittenState == .ready
        case .kokoro: return voice.kokoroState == .ready
        }
    }

    private var engineChip: some View {
        HStack(spacing: 5) {
            Image(systemName: engineSymbol)
                .font(.system(size: 9, weight: .semibold))
            Text(engineLabel)
                .font(T.mono(9.5, .semibold))
        }
        .foregroundColor(T.ink3)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(
            Capsule().fill(T.surface)
                .overlay(Capsule().stroke(T.rule, lineWidth: 0.5))
        )
        .accessibilityLabel("TTS engine: \(engineLabel)")
    }

    private var fallbackChip: some View {
        chip("Apple TTS fallback", color: T.warn)
            .accessibilityLabel("Apple TTS fallback is active")
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(T.mono(9, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.12))
                    .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            )
    }

    private var testAudioButton: some View {
        Button {
            runAudioTest()
        } label: {
            HStack(spacing: 4) {
                if testTTSInFlight {
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(T.accent)
                } else {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(loc.t("test audio"))
                    .font(T.mono(9.5, .semibold))
            }
            .foregroundColor(T.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule().fill(T.accentSoft)
                    .overlay(Capsule().stroke(T.accent.opacity(0.3), lineWidth: 0.5))
            )
        }
        .buttonStyle(.plain)
        .disabled(testTTSInFlight)
        .accessibilityLabel(loc.t("test audio"))
    }

    private var engineSymbol: String {
        // Show preferred store selection; live engine may differ on fallback.
        switch voiceSettings.selectedEngine {
        case .appleSystem: return "applelogo"
        case .kittenTTS:   return "pawprint.fill"
        case .kokoro:      return "leaf.fill"
        }
    }

    private var engineLabel: String {
        if voiceControls.isFallbackEngine {
            return "Apple TTS"
        }
        switch voice.currentEngineKind {
        case .appleSystem:
            // Prefer store selection name when Apple is intentional.
            if voiceSettings.selectedEngine == .appleSystem { return "Apple TTS" }
            return "Apple TTS"
        case .kittenTTS: return "KittenTTS"
        case .kokoro: return "Kokoro"
        }
    }

    private var activeVoiceLabel: String {
        let id = voiceSettings.selectedVoiceID
        if let match = voice.availableVoices.first(where: { $0.id == id }) {
            return "\(match.name) · \(voiceSettings.selectedEngine.shortName)"
        }
        if voiceSettings.selectedEngine == .appleSystem {
            return "System voice · Apple TTS"
        }
        return "\(voiceSettings.selectedEngine.shortName) voice"
    }

    private var fallbackDetail: String? {
        voiceControls.isFallbackEngine ? "Fallback active" : nil
    }

    private var orbAccent: Color {
        switch uiPhase {
        case .idle: return T.ink3
        case .listening, .speechDetected: return T.accent
        case .thinking, .preparingSpeech: return T.warn
        case .speaking: return T.good
        case .paused, .interrupted: return T.warn
        case .failed: return T.bad
        }
    }

    // MARK: - Transcript

    private var transcriptArea: some View {
        VStack(spacing: 10) {
            if !conv.liveTranscript.isEmpty {
                VoiceUserTranscriptBubble(text: conv.liveTranscript)
            }

            KaraokeTranscriptContainer(
                karaoke: SpeechPlaybackCoordinator.shared.karaoke,
                // Skip the strip pass while speakable text exists — the
                // fallback is only read when karaoke.text is empty, and
                // computing it per body eval was O(n²) over the reply.
                fallbackText: karaokeText.isEmpty ? fallbackKaraokeText : "",
                isExpanded: false,
                onToggleExpand: { isTranscriptExpanded = true },
                onCopy: { UIPasteboard.general.string = displayKaraokeText },
                onReplay: canReplay ? { replayLastReply() } : nil
            )

            if displayKaraokeText.isEmpty && conv.phase == .listening {
                Text(loc.t("Say something — I'm listening."))
                    .font(T.sans(13))
                    .foregroundColor(T.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: conv.liveTranscript)
    }

    /// Prefer coordinator speakable text for karaoke ranges; fall back to stripped live reply.
    private var displayKaraokeText: String {
        if !karaokeText.isEmpty { return karaokeText }
        return fallbackKaraokeText
    }

    private var fallbackKaraokeText: String {
        let stripped = ReasoningStripper.strip(conv.liveReply)
        return stripped.isEmpty ? conv.liveReply : stripped
    }

    private var canReplay: Bool {
        !displayKaraokeText.isEmpty && conv.phase != .speaking && conv.phase != .thinking
    }

    private var expandedTranscriptSheet: some View {
        NavigationStack {
            KaraokeTranscriptContainer(
                karaoke: SpeechPlaybackCoordinator.shared.karaoke,
                fallbackText: karaokeText.isEmpty ? fallbackKaraokeText : "",
                isExpanded: true,
                onToggleExpand: { isTranscriptExpanded = false },
                onCopy: { UIPasteboard.general.string = displayKaraokeText },
                onReplay: canReplay ? { replayLastReply() } : nil
            )
            .padding()
            .navigationTitle(loc.t("assistant"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("Done")) { isTranscriptExpanded = false }
                }
            }
            // Keep interrupt reachable while expanded via toolbar.
            .toolbar {
                if conv.phase == .speaking || conv.phase == .thinking {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(loc.t("interrupt")) { interruptNow() }
                            .foregroundStyle(T.warn)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func failureBanner(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Text(msg)
                .font(T.sans(13))
                .foregroundColor(T.bad)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { _ = await conv.start() }
            }
            .font(T.mono(11, .semibold))
            .foregroundStyle(T.accent)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .kGlass(cornerRadius: 14, fallbackFill: T.surface)
    }

    // MARK: - Control dock

    private var controlDock: some View {
        HStack(spacing: 18) {
            dockButton(
                systemImage: "xmark",
                label: loc.t("end"),
                tint: T.bad,
                accessibility: loc.t("End conversation")
            ) {
                if !conv.liveReply.isEmpty || voice.isPlaying {
                    confirmEnd = true
                } else {
                    conv.stop()
                    dismiss()
                    HapticManager.impact(.medium)
                }
            }

            dockButton(
                systemImage: voiceAnswerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                label: voiceAnswerEnabled ? "Mute voice" : "Unmute voice",
                tint: voiceAnswerEnabled ? T.accent : T.ink3,
                accessibility: voiceAnswerEnabled
                    ? "Mute voice output"
                    : "Unmute voice output"
            ) {
                voiceAnswerEnabled.toggle()
                HapticManager.impact(.light)
            }

            if conv.phase == .speaking || conv.phase == .thinking {
                dockButton(
                    systemImage: "hand.raised.fill",
                    label: loc.t("interrupt"),
                    tint: T.warn,
                    accessibility: loc.t("Interrupt and speak")
                ) {
                    interruptNow()
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                dockButton(
                    systemImage: "mic.fill",
                    label: loc.t("listening"),
                    tint: T.ink3,
                    accessibility: loc.t("listening")
                ) {
                    // No-op visual balance; listening is automatic.
                }
                .opacity(0.45)
                .disabled(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(T.rule.opacity(0.6), lineWidth: 0.5)
                )
        )
        .animation(.spring(duration: 0.3), value: conv.phase)
    }

    private func dockButton(
        systemImage: String,
        label: String,
        tint: Color,
        accessibility: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(tint.opacity(0.14)))
                Text(label)
                    .font(T.mono(10, .semibold))
                    .foregroundStyle(T.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    // MARK: - Actions

    private func interruptNow() {
        // Audible stop first — do not wait on actor cleanup.
        VoicePerformanceMonitor.shared.noteInterruptRequested()
        voice.stop()
        playbackCoord.interruptImmediately()
        HapticManager.impact(.heavy)
        interruptFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            interruptFlash = false
        }
        Task { await conv.interrupt() }
    }

    private func syncMute() {
        playbackCoord.setMuted(!voiceAnswerEnabled)
    }

    private func runAudioTest() {
        let convPhase = VoiceConversationService.shared.phase
        guard convPhase != .thinking, convPhase != .speaking else {
            ToastCenter.shared.info("Finish the current reply first")
            return
        }
        HapticManager.impact(.light)
        testTTSInFlight = true
        VoiceConversationService.shared.prepareForTTSPlayback()
        let phrase = loc.t("Audio test. If you hear this, voice replies will play.")
        VoiceService.shared.speak(phrase)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            let deadline = Date().addingTimeInterval(8)
            while VoiceService.shared.isPlaying && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            testTTSInFlight = false
            // Ensure we never leave the orb stuck in speaking after a test.
            if VoiceConversationService.shared.phase == .listening {
                SpeechPlaybackCoordinator.shared.bindSessionPhase(.listening)
            }
            VoiceConversationService.shared.restoreListeningAfterTTS()
        }
    }

    private func replayLastReply() {
        let text = displayKaraokeText
        guard !text.isEmpty else { return }
        let convPhase = conv.phase
        guard convPhase != .thinking, convPhase != .speaking else { return }
        conv.prepareForTTSPlayback()
        voice.speak(text)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            while voice.isPlaying {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            conv.restoreListeningAfterTTS()
        }
    }

    private func announcePhase(_ phase: VoiceSessionPhase) {
        // Phase changes only — never every karaoke word.
        UIAccessibility.post(notification: .announcement, argument: phase.statusLabel)
    }

    private var uiPhase: VoiceSessionPhase {
        if voiceControls.phase == .interrupted {
            return .interrupted
        }
        let mapped = mapPhase(conv.phase)
        // Orb may be in speechDetected while the conversation service is
        // still .listening — prefer the richer UI phase for accent/status.
        if mapped == .listening,
           SpeechPlaybackCoordinator.shared.orb.phase == .speechDetected {
            return .speechDetected
        }
        return mapped
    }

    private func mapPhase(_ phase: VoiceConversationService.Phase) -> VoiceSessionPhase {
        switch phase {
        case .idle: return .idle
        case .listening: return .listening
        case .thinking:
            return voice.isPlaying ? .speaking : .thinking
        case .speaking:
            // Keep `.speaking` even before the first buffer is audible so the
            // orb opens its output gate and reacts as soon as levels arrive.
            return .speaking
        case .failed(let msg): return .failed(msg)
        }
    }

    /// Avoid clobbering service-driven orb states (speechDetected, speaking).
    private func shouldViewBindPhase(
        _ mapped: VoiceSessionPhase,
        servicePhase: VoiceConversationService.Phase
    ) -> Bool {
        switch servicePhase {
        case .listening:
            // Preserve speechDetected until thinking/speaking takes over.
            if playbackCoord.orb.phase == .speechDetected { return false }
            return mapped == .listening
        case .speaking, .thinking:
            // Service binds these at the exact transition; view re-bind is
            // only needed if we somehow drifted to idle/failed.
            switch playbackCoord.orb.phase {
            case .idle, .failed, .paused: return true
            default: return false
            }
        case .idle, .failed:
            return true
        }
    }
}

// MARK: - VoiceModelPickerSheet

private struct VoiceModelPickerSheet: View {

    @ObservedObject private var conv = VoiceConversationService.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var loc = LocalizationService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    private var downloadedModels: [DownloadableModel] {
        let candidates = center.models.filter { m in
            guard m.isReady, !m.isRequired, m.category == .assistant else { return false }
            return !AssistantModelCatalog.presets.contains { $0.repoID == m.id }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    matchChatTabRow
                    presetsSection
                    if !downloadedModels.isEmpty {
                        downloadedSection
                    }
                    footnote
                }
                .padding(.bottom, 32)
            }
            .background(LiquidPinkBackdrop())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(loc.t("Done")) { dismiss() }.foregroundColor(T.ink)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            KCaption(text: loc.t("VOICE"))
            KPageTitle(title: loc.t("voice model"), size: 28)
            KMono(text: loc.t("the llm used while you're in voice conversation mode"),
                  size: 11, color: T.ink3)
                .padding(.top, 2)
            KMono(text: loc.t("tip: a smaller model replies faster — latency matters more than raw smarts in a spoken back-and-forth"),
                  size: 10, color: T.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var matchChatTabRow: some View {
        let isMatching = conv.voiceModelID == nil
        return KSection(title: loc.t("default")) {
            Button {
                Task {
                    await conv.setVoiceModel(nil)
                    dismiss()
                }
            } label: {
                HStack(spacing: 10) {
                    radio(isSelected: isMatching)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("match chat tab"))
                            .font(T.mono(13, .semibold))
                            .foregroundColor(T.ink)
                        KMono(text: loc.t("voice mode uses whatever the chat tab is using"),
                              size: 10, color: T.ink3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var presetsSection: some View {
        KSection(title: loc.t("presets")) {
            ForEach(Array(AssistantModelCatalog.presets.enumerated()), id: \.offset) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                row(id: m.id, name: m.displayName, subtitle: m.subtitle)
            }
        }
    }

    private var downloadedSection: some View {
        KSection(title: loc.t("downloaded")) {
            ForEach(Array(downloadedModels.enumerated()), id: \.offset) { i, m in
                if i > 0 { Rectangle().fill(T.rule).frame(height: 1) }
                row(id: LocalModelRegistry.assistantSelectionID(for: m.id,
                                                                origin: LocalModelRegistry.origin(for: m)),
                    name: m.displayName,
                    subtitle: m.subtitle.isEmpty ? loc.t("ready · on device") : m.subtitle)
            }
        }
    }

    @ViewBuilder
    private func row(id modelID: String, name: String, subtitle: String) -> some View {
        let isSelected = conv.voiceModelID == modelID
        Button {
            Task {
                await conv.setVoiceModel(modelID)
                dismiss()
            }
        } label: {
            HStack(spacing: 10) {
                radio(isSelected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(T.mono(13, .semibold))
                        .foregroundColor(T.ink)
                    KMono(text: subtitle, size: 10, color: T.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func radio(isSelected: Bool) -> some View {
        ZStack {
            Circle().stroke(isSelected ? T.accent : T.rule2, lineWidth: 1.5)
                .frame(width: 16, height: 16)
            if isSelected {
                Circle().fill(T.accent).frame(width: 9, height: 9)
            }
        }
    }

    private var footnote: some View {
        KMono(
            text: loc.t("tip: a smaller model (≤1.5B) keeps the back-and-forth snappy and avoids overheating during long voice sessions."),
            size: 10, color: T.ink3
        )
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }
}
