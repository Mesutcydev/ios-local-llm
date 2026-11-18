import SwiftUI

// MARK: - Isolated observation boundaries
// Orb never observes karaoke; karaoke never observes amplitude.
// VoiceConversationView observes neither model, so it is never invalidated
// by playback progress. The orb renders independently in Metal.

struct VoiceOrbContainer: View {
    @ObservedObject var orb: OrbPresentationModel
    let reduceMotion: Bool
    let onTap: () -> Void
    let onInterrupt: () -> Void
    var flash: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width * 0.64, 280)
            ZStack {
                VoiceActivityOrb(
                    phase: orb.phase,
                    micLevel: 0, // mic amplitude via VoiceVisualLevelStore
                    reduceMotion: reduceMotion,
                    renderingMode: orb.renderingMode
                )
                .frame(width: diameter, height: diameter)

                Circle()
                    .fill(Color.white.opacity(flash ? 0.55 : 0))
                    .frame(width: diameter, height: diameter)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: diameter)
            .contentShape(Circle())
            .onTapGesture {
                switch orb.phase {
                case .idle:
                    onTap()
                case .speaking, .thinking, .preparingSpeech:
                    onInterrupt()
                case .listening, .speechDetected, .paused, .interrupted, .failed:
                    break
                }
            }
        }
        .frame(maxHeight: 280)
    }
}

struct KaraokeTranscriptContainer: View {
    @ObservedObject var karaoke: KaraokePresentationModel
    let fallbackText: String
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    var onCopy: (() -> Void)? = nil
    var onReplay: (() -> Void)? = nil

    var body: some View {
        let text = karaoke.text.isEmpty ? fallbackText : karaoke.text
        if !text.isEmpty {
            // Text, phrase and the word-stepped spoken end all arrive via
            // @ObservedObject — only this container observes the model.
            KaraokeTranscriptView(
                text: text,
                activePhraseID: karaoke.activePhraseID,
                activeRange: karaoke.activePhraseUTF16Range,
                spokenUTF16End: karaoke.spokenUTF16End,
                isExpanded: isExpanded,
                onToggleExpand: onToggleExpand,
                onCopy: onCopy,
                onReplay: onReplay
            )
        }
    }
}
