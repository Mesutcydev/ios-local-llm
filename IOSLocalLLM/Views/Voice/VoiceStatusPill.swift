import SwiftUI

// MARK: - VoiceStatusPill
//
// Compact status indicator for the streaming TTS pipeline. Shows
// the active model name plus the BCP-47 language of the currently-
// playing utterance (rendered as a flag emoji where possible). Hides
// itself when the queue isn't speaking — its existence is a signal
// that the pipeline is active.
//
// Reusable across three surfaces (per session-3 spec):
//
//   • Voice-conversation tab — replaces the old engine chip.
//   • Lens tab — visible next to the caption when Lens streaming
//     TTS is on.
//   • Assistant tab — header chip when voice-answer mode is on.
//
// Tap opens the Voice Settings sheet so the user can adjust profile,
// engine, or rate in one motion.

struct VoiceStatusPill: View {

    /// Queue to observe for live state. Pass the queue that's
    /// actually driving audio for the surface the pill is shown on
    /// — `VoiceService.shared` exposes the assistant-conversation
    /// queue via its `speakStream`; `LensVoiceNarrator.shared`
    /// exposes its own queue for the Lens surface.
    @ObservedObject var audioQueue: AudioQueue

    /// Display name of the model driving the active stream. Caller
    /// pulls this from `CodingAssistantService.shared.activeModel`
    /// for Assistant contexts or `LensInferenceLoop.shared` for
    /// Lens contexts.
    let modelName: String

    @Environment(\.koduTheme) private var T
    @State private var showVoiceSettings = false

    var body: some View {
        // Visibility is controlled by `isSpeaking` — the pill is a
        // signal that the pipeline is live RIGHT NOW. Hide entirely
        // when idle so it doesn't add visual noise to surfaces that
        // share its slot with other content.
        if audioQueue.isSpeaking {
            content
                .transition(.scale.combined(with: .opacity))
                .animation(.easeInOut(duration: 0.18), value: audioQueue.isSpeaking)
                .sheet(isPresented: $showVoiceSettings) {
                    VoiceSettingsView()
                }
        }
    }

    private var content: some View {
        Button {
            HapticManager.impact(.light)
            showVoiceSettings = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(T.accent)

                Text(modelName)
                    .font(T.mono(10, .semibold))
                    .tracking(0.3)
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140, alignment: .leading)

                if let flag = Self.flagEmoji(forBCP47: audioQueue.currentLanguage), !flag.isEmpty {
                    Text(flag)
                        .font(.system(size: 11))
                        .accessibilityLabel(audioQueue.currentLanguage ?? "")
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .kGlassCapsule(fallbackFill: T.surface)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice on: \(modelName)\(audioQueue.currentLanguage.map { ", \($0)" } ?? "")")
        .accessibilityHint("Opens voice settings")
    }

    // MARK: - BCP-47 → flag emoji
    //
    // Strips the region (last hyphen-separated segment) and maps
    // it to the two regional-indicator symbols whose juxtaposition
    // renders as the country flag. Tags without a 2-letter region
    // (e.g. bare `en`) return nil so the caller hides the slot
    // entirely rather than showing a fallback glyph.

    static func flagEmoji(forBCP47 tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        // Require an explicit `-region` segment — otherwise a bare
        // language code like `en` (2 letters, all alpha) would be
        // misread as the region "EN" (Spain has region "ES";
        // "EN" maps to no real country flag glyph but the regional-
        // indicator emoji still renders a placeholder pair).
        let parts = tag.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let region = String(parts.last!)
        guard region.count == 2,
              region.allSatisfy({ $0.isLetter })
        else { return nil }

        let upper = region.uppercased()
        var emoji = ""
        let base: UInt32 = 0x1F1E6   // 🇦
        let baseLetterValue = UnicodeScalar("A").value
        for scalar in upper.unicodeScalars {
            guard scalar.value >= baseLetterValue,
                  scalar.value <= UnicodeScalar("Z").value
            else { return nil }
            let offset = scalar.value - baseLetterValue
            if let s = UnicodeScalar(base + offset) {
                emoji.append(Character(s))
            }
        }
        return emoji.isEmpty ? nil : emoji
    }
}
