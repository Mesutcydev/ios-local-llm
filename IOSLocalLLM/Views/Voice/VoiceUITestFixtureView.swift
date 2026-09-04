import SwiftUI

#if DEBUG

/// Deterministic Voice Mode surface for UI tests. Activated only when
/// `-voiceUITestMode` is present in launch arguments. Never used in Release.
struct VoiceUITestFixtureView: View {
    @State private var transcript = ProcessInfo.processInfo.environment["MOCK_TRANSCRIPT"]
        ?? "This is a deterministic assistant response used for Voice Mode UI tests. It is long enough to require scrolling when collapsed, and it includes several sentences so karaoke highlighting can advance."
    @State private var expanded = false
    @State private var followSpeech = true
    @State private var playbackTime: Double = 0
    @State private var phase: VoiceSessionPhase = .speaking
    @State private var level: Float = 0.35
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mockDuration: Double {
        let raw = UserDefaults.standard.string(forKey: "mockDuration")
            ?? ProcessInfo.processInfo.arguments.drop(while: { $0 != "-mockDuration" }).dropFirst().first
        return Double(raw ?? "20") ?? 20
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Conversation model")
                .font(.caption)
                .accessibilityIdentifier("conversationModelLabel")
            Text("Ternary Bonsai 8B")
                .font(.headline)
                .accessibilityIdentifier("conversationModelValue")

            Text("Voice")
                .font(.caption)
            Text(mockVoiceLabel)
                .font(.subheadline)
                .accessibilityIdentifier("ttsVoiceValue")

            VoiceActivityOrb(
                phase: phase,
                micLevel: 0,
                reduceMotion: reduceMotion
            )
            .frame(width: 200, height: 200)
            .onAppear {
                VoiceVisualLevelStore.shared.playbackLevel = level
            }
            .onChange(of: level) { _, newLevel in
                VoiceVisualLevelStore.shared.playbackLevel = newLevel
            }

            KaraokeTranscriptView(
                text: transcript,
                activePhraseID: nil,
                activeRange: activeRange,
                spokenUTF16End: spokenEnd,
                isExpanded: expanded,
                onToggleExpand: { expanded.toggle() }
            )
            .accessibilityIdentifier("karaokeTranscript")

            if !followSpeech {
                Button("Follow speech") { followSpeech = true }
                    .accessibilityIdentifier("followSpeechButton")
            }

            HStack {
                Button("End") {}
                    .accessibilityIdentifier("endButton")
                Button("Mute voice") {}
                    .accessibilityIdentifier("muteButton")
                Button("Interrupt") {
                    phase = .interrupted
                    level = 0
                }
                .accessibilityIdentifier("interruptButton")
            }
        }
        .padding()
        .onAppear { startMockPlayback() }
    }

    private var mockVoiceLabel: String {
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-mockTTS"), args.indices.contains(idx + 1) {
            switch args[idx + 1].lowercased() {
            case "kitten": return "KittenTTS — Bella"
            case "kokoro": return "Kokoro — American English"
            default: return "Apple TTS — Samantha"
            }
        }
        return "Kokoro — American English"
    }

    private var spokenEnd: Int {
        let len = (transcript as NSString).length
        return Int(Double(len) * min(1, playbackTime / max(mockDuration, 1)))
    }

    private var activeRange: NSRange? {
        let len = (transcript as NSString).length
        guard len > 0, phase == .speaking else { return nil }
        let loc = min(spokenEnd, len - 1)
        return NSRange(location: loc, length: min(4, len - loc))
    }

    private func startMockPlayback() {
        phase = .speaking
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            playbackTime += 0.25
            level = reduceMotion ? 0.1 : Float(0.2 + 0.3 * abs(sin(playbackTime)))
            if playbackTime >= mockDuration {
                timer.invalidate()
                phase = .idle
                level = 0
            }
        }
    }
}

enum VoiceUITestLaunch {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-voiceUITestMode")
    }
}


/// Uses real release views with deterministic search data and no download.
struct ReleaseUITestFixtureView: View {
    private let environment = ProcessInfo.processInfo.environment

    var body: some View {
        content
            .koduTheme(KoduTheme.make(appearance: environment["RELEASE_DARK"] == "1" ? "dark" : "light",
                                      accent: KoduTheme.appAccent))
            .preferredColorScheme(environment["RELEASE_DARK"] == "1" ? .dark : .light)
            .dynamicTypeSize(environment["RELEASE_LARGE"] == "1" ? .accessibility5 : .large)
    }

    @ViewBuilder private var content: some View {
        switch environment["RELEASE_SCREEN"] {
        case "onboarding": OnboardingView()
        case "settings": SettingsView(assistant: CodingAssistantService.shared)
        case "home": HomeView(onNewChat: {}, onOpenLens: {}, onOpenVoice: {}, onOpenModels: {},
                              onOpenMac: {}, onGenerateImage: {}, onOpenSettings: {}, onOpenConversation: { _ in })
        default:
            HFSearchView(service: HFSearchService { request in
                let data = Data(#"[{"id":"mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit","tags":["mlx","license:apache-2.0"],"pipeline_tag":"text-generation","downloads":1200}]"#.utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, estimateSizes: false)
        }
    }
}

#endif
