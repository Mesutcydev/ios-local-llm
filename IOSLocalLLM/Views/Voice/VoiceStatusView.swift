import SwiftUI

// MARK: - VoiceStatusView
// Shows the load state of each voice engine.
// Embedded in SettingsView's Voice section.

struct VoiceStatusView: View {

    @ObservedObject private var voiceService = VoiceService.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(spacing: 0) {
            engineRow("apple system voice", state: voiceService.systemState,
                      note: "always available — no download needed")
            Rectangle().fill(T.rule).frame(height: 1)
            engineRow("kittentts (on-device)", state: voiceService.kittenState,
                      note: kittenNote)
            Rectangle().fill(T.rule).frame(height: 1)
            engineRow("kokoro (experimental)", state: voiceService.kokoroState,
                      note: kokoroNote)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func engineRow(_ label: String, state: VoiceModelState, note: String) -> some View {
        HStack(spacing: 10) {
            Text(stateGlyph(state))
                .font(T.mono(10))
                .foregroundColor(stateColor(state))

            VStack(alignment: .leading, spacing: 2) {
                KMono(text: label, size: 12, color: T.ink)
                KMono(text: note, size: 9, color: T.ink3)
            }

            Spacer()

            KMono(text: state.statusLabel.lowercased(), size: 10, color: T.ink3)
        }
        .padding(.vertical, 8)
    }

    private var kittenNote: String {
        VoiceModelBundleValidator.isKittenTTSAvailable()
            ? "model found — tap load to activate"
            : "run scripts/download_voice_models.sh"
    }

    private var kokoroNote: String {
        VoiceModelBundleValidator.isKokoroAvailable()
            ? "model found — tap load to activate (experimental)"
            : "run scripts/download_voice_models.sh"
    }

    private func stateGlyph(_ state: VoiceModelState) -> String {
        switch state {
        case .ready:    return "●"
        case .loading:  return "◐"
        case .failed:   return "✕"
        case .unloaded: return "○"
        }
    }
    private func stateColor(_ state: VoiceModelState) -> Color {
        switch state {
        case .ready:    return T.good
        case .loading:  return T.warn
        case .failed:   return T.bad
        case .unloaded: return T.ink3
        }
    }
}
