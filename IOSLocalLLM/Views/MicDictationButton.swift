import SwiftUI

// MARK: - MicDictationButton
// Hold-to-talk mic button. Tap-and-hold (or single-tap to toggle) starts
// speech recognition; the transcript is written into the bound text.
//
// Use it next to a TextField/TextEditor:
//   MicDictationButton(text: $inputText)

struct MicDictationButton: View {
    @Binding var text: String
    @StateObject private var dictation = SpeechDictationService()
    @State private var preCaptureText: String = ""    // baseline before this session
    @State private var permissionsRequested = false
    @State private var showDeniedSheet = false

    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var localization = LocalizationService.shared

    /// When true, show the recording state inline as a chip; otherwise toggle the icon only.
    var compact: Bool = false
    var composerStyle: Bool = false

    var body: some View {
        Button {
            HapticManager.impact(.light)
            Task { await toggleRecording() }
        } label: {
            iconLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(localization.t(dictation.isRecording ? "Stop dictation" : "Dictate a message"))
        .accessibilityValue(localization.t(dictation.isRecording ? "Listening" : "Ready"))
        .onDisappear { dictation.stop() }
        .alert("Microphone access needed",
               isPresented: $showDeniedSheet) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable microphone and speech recognition for iOS Local LLM in Settings → Privacy.")
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var iconLabel: some View {
        if composerStyle {
            Image(systemName: dictation.isRecording ? "stop.fill" : "mic")
                .font(.system(size: dictation.isRecording ? 16 : 20, weight: .medium))
                .foregroundStyle(dictation.isRecording ? T.bad : T.ink2)
                .frame(width: 44, height: 44)
                .background(dictation.isRecording ? T.bad.opacity(0.10) : .clear, in: Circle())
                .contentShape(Circle())
        } else if dictation.isRecording {
            // Recording: red pulsing dot + level meter
            HStack(spacing: 6) {
                Circle()
                    .fill(T.bad)
                    .frame(width: 8, height: 8)
                    .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(dictation.levelMeter) * 0.6)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: dictation.levelMeter)
                if !compact {
                    Text("listening")
                        .font(T.mono(11, .semibold))
                        .foregroundColor(T.bad)
                }
            }
            .padding(.horizontal, compact ? 0 : 8)
            .frame(width: compact ? 36 : nil, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(T.bad.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(T.bad.opacity(0.4), lineWidth: 1)
            )
        } else {
            // Idle: standard mic icon button
            Image(systemName: "mic")
                .font(.system(size: 14))
                .foregroundColor(T.ink2)
                .frame(width: 36, height: 36)
                .kGlass(cornerRadius: 6, fallbackFill: T.surface)
        }
    }

    // MARK: - Actions

    private func toggleRecording() async {
        if dictation.isRecording {
            dictation.stop()
            return
        }

        // Request permissions on first use
        if !permissionsRequested {
            permissionsRequested = true
            let ok = await dictation.requestAuthorization()
            if !ok {
                showDeniedSheet = true
                return
            }
        } else if !dictation.isAuthorized {
            showDeniedSheet = true
            return
        }

        guard dictation.isAvailable else {
            ToastCenter.shared.error("Speech recognition unavailable",
                                      detail: dictation.lastError ?? "Try again in a moment.")
            return
        }

        preCaptureText = text
        do {
            try dictation.start { transcript, isFinal in
                let glue: String = preCaptureText.isEmpty
                    ? ""
                    : (preCaptureText.hasSuffix(" ") ? "" : " ")
                text = preCaptureText + glue + transcript
                if isFinal { HapticManager.impact(.light) }
            }
        } catch {
            ToastCenter.shared.error("Couldn't start dictation",
                                      detail: error.localizedDescription)
        }
    }
}
