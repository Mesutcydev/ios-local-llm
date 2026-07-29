#if DEBUG

import SwiftUI

// MARK: - VoiceValidationView
// DEBUG-only panel for physical-device validation. Not compiled into Release.

struct VoiceValidationView: View {
    @ObservedObject private var assistant = CodingAssistantService.shared
    @ObservedObject private var voiceSettings = VoiceSettingsStore.shared
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var playback = SpeechPlaybackCoordinator.shared
    @ObservedObject private var routes = VoiceAudioSessionManager.shared
    @ObservedObject private var soak = VoiceSoakHarness.shared
    @ObservedObject private var diag = VoiceDiagnosticsCenter.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T

    @State private var report = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    labeled("Conversation model", assistant.activeModel.displayName)
                    labeled("TTS engine (store)", voiceSettings.selectedEngine.shortName)
                    labeled("TTS engine (live)", voice.currentEngineKind.shortName)
                    labeled("Voice ID", voiceSettings.selectedVoiceID.isEmpty ? "—" : voiceSettings.selectedVoiceID)
                    labeled("Restored engine", voiceSettings.selectedEngine.rawValue)
                }

                Section("Playback") {
                    labeled("Phase", playback.snapshot.phase.statusLabel)
                    labeled("Alignment", playback.snapshot.timingSource?.diagnosticLabel ?? "—")
                    labeled("Detail", playback.snapshot.alignmentDetail ?? "—")
                    labeled("Time", String(format: "%.2f / %.2f", playback.snapshot.currentTime, playback.snapshot.duration))
                    labeled("Level", String(format: "%.3f", playback.snapshot.normalizedLevel))
                    labeled("Route", routes.route.displayName)
                    labeled("Route change", routes.lastRouteChangeReason.isEmpty ? "—" : routes.lastRouteChangeReason)
                }

                Section("Test actions") {
                    Button("Speak 30s English script") { speak(Self.script30s) }
                    Button("Speak punctuation script") { speak(Self.scriptPunctuation) }
                    Button("Speak Turkish") { speak("Merhaba! Bu, Türkçe bir test cümlesidir; sayılar: 1, 2, 3.") }
                    Button("Speak Arabic") { speak("مرحبا بالعالم. هذه جملة اختبار للتحقق من المحاذاة.") }
                    Button("Interrupt after 5s") { interruptAfter(5) }
                    Button("Test voice restore toast") {
                        ToastCenter.shared.info(
                            "Voice restore check",
                            detail: "Store engine=\(voiceSettings.selectedEngine.shortName)"
                        )
                    }
                    Button("Refresh route") { routes.refreshRoute() }
                }

                Section("Soak") {
                    Text(soak.status)
                        .font(.footnote)
                    Text("Cycles: \(soak.cyclesCompleted)")
                        .font(.footnote)
                    Button("Start 15m quick soak") { soak.run(durationMinutes: 15) }
                        .disabled(soak.isRunning)
                    Button("Start 60m extended soak") { soak.run(durationMinutes: 60) }
                        .disabled(soak.isRunning)
                    Button("Stop soak", role: .destructive) { soak.stop() }
                        .disabled(!soak.isRunning)
                }

                Section("Report") {
                    Button("Generate diagnostic report") {
                        report = diag.snapshotReport(
                            conversationModel: assistant.activeModel.displayName,
                            ttsEngine: "\(voiceSettings.selectedEngine.shortName) / live \(voice.currentEngineKind.shortName)",
                            voiceID: voiceSettings.selectedVoiceID,
                            route: routes.route.displayName,
                            alignment: playback.snapshot.timingSource?.diagnosticLabel ?? "—",
                            phase: playback.snapshot.phase.statusLabel
                        )
                    }
                    if !report.isEmpty {
                        Text(report)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                        ShareLink(item: report) {
                            Label("Share report", systemImage: "square.and.arrow.up")
                        }
                    }
                }

                Section("Physical checklist") {
                    Text(Self.checklist)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Voice Validation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Voice Mode already owns route observation via VoiceRouteControl;
                // only refresh the snapshot so we do not double-register.
                routes.refreshRoute()
                diag.syncLiveState()
            }
            .onDisappear {
                diag.syncLiveState()
            }
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
        }
    }

    private func speak(_ text: String) {
        VoiceConversationService.shared.prepareForTTSPlayback()
        VoiceService.shared.speak(text)
    }

    private func interruptAfter(_ seconds: Double) {
        speak(Self.script30s)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let t0 = Date()
            await VoiceConversationService.shared.interrupt()
            VoiceDiagnosticsCenter.shared.noteInterruptionLatency(Date().timeIntervalSince(t0) * 1000)
        }
    }

    private static let script30s = """
    This is a thirty second validation script for Voice Mode. It covers several sentences \
    so karaoke can advance across clause boundaries. Commas, periods, and questions? Yes. \
    We also include a short list: one, two, and three. Please listen for amplitude motion \
    on the orb, and confirm highlighting tracks the spoken words without large drift.
    """

    private static let scriptPunctuation = """
    Wait — really? Yes: commas, semicolons; dashes — and ellipses… all in one line!
    """

    private static let checklist = """
    PHYSICAL DEVICE CHECKLIST
    Conversation model: Ternary Bonsai 8B (LLM only)
    TTS: test Kitten, Kokoro, Apple separately

    [ ] Bonsai labeled as Conversation model
    [ ] TTS engine labeled separately under Voice
    [ ] Voice persists after close/reopen
    [ ] Voice persists after app relaunch
    [ ] Missing voice shows visible fallback
    [ ] Orb reacts to real amplitude
    [ ] Orb stops on silence / end / interrupt
    [ ] Karaoke follows speech reasonably
    [ ] Manual scroll detaches; Follow speech restores
    [ ] Full transcript readable after completion
    [ ] AirPods connect updates route label
    [ ] AirPods disconnect recovers
    [ ] Route change does not restart full response
    [ ] Background/foreground no duplicate audio
    [ ] Rapid interrupt does not crash
    """
}

#endif
