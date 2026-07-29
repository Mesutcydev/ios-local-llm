import SwiftUI

// MARK: - VoiceControlsView
// "Read Aloud" / "Stop" button row embedded in AnalysisPanelView's action row.
// Studio-style: surface fill, mono labels.

struct VoiceControlsView: View {

    let text: String
    @ObservedObject private var voiceService = VoiceService.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        if voiceService.isPlaying {
            stopButton
        } else {
            readAloudButton
        }
    }

    private var readAloudButton: some View {
        Button {
            HapticManager.impact(.light)
            voiceService.speak(text)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12))
                Text("read")
                    .font(T.mono(12))
            }
            .foregroundColor(T.ink2)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .kGlass(cornerRadius: 6, fallbackFill: T.surface)
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button {
            HapticManager.impact(.light)
            voiceService.stop()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.circle")
                    .font(.system(size: 12))
                Text("stop")
                    .font(T.mono(12, .semibold))
            }
            .foregroundColor(T.warn)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.warn.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - VoicePlaybackStatusBadge

struct VoicePlaybackStatusBadge: View {
    @ObservedObject private var voiceService = VoiceService.shared
    @Environment(\.koduTheme) private var T

    var body: some View {
        if voiceService.isPlaying {
            HStack(spacing: 5) {
                SpeakerAnimationView()
                KMono(text: "speaking via \(voiceService.currentEngineKind.shortName.lowercased())…",
                       size: 10, color: T.ink3)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        }
    }
}

// MARK: - SpeakerAnimationView

struct SpeakerAnimationView: View {
    @State private var phase: Double = 0
    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Capsule()
                    .fill(T.ink2)
                    .frame(width: 2, height: 4 + CGFloat(sin(phase + Double(i) * .pi / 2)) * 3)
            }
        }
        .frame(width: 12, height: 12)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}
