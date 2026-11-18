import Combine
import Foundation

// MARK: - Narrow presentation models
// VoiceConversationView observes these independently so orb amplitude
// never invalidates karaoke, and phrase changes never redraw the orb.

@MainActor
final class OrbPresentationModel: ObservableObject {
    @Published var phase: VoiceSessionPhase = .idle
    /// Coarse 0…1 level published at ≤30 Hz for non-renderer consumers.
    /// The Metal orb reads VoiceVisualLevelStore directly on its render loop.
    @Published var publishedLevel: Float = 0
    @Published var renderingMode: VoiceRenderingMode = .automatic
    @Published var canInterrupt: Bool = false
}

@MainActor
final class KaraokePresentationModel: ObservableObject {
    @Published var text: String = ""
    @Published var activePhraseID: UUID?
    @Published var activePhraseUTF16Range: NSRange?
    /// Steps once per spoken word (a few Hz), so it can simply be published.
    /// The old per-frame cursor could not — at 30–60 Hz it made the screen
    /// flutter — and had to be polled instead.
    @Published private(set) var spokenUTF16End: Int = 0
    @Published var timingSource: SpeechAlignmentAccuracy?
    @Published var alignmentDetail: String?

    func setSpokenUTF16End(_ value: Int) {
        if value != spokenUTF16End { spokenUTF16End = value }
    }
}

@MainActor
final class ControlsPresentationModel: ObservableObject {
    @Published var phase: VoiceSessionPhase = .idle
    @Published var canInterrupt: Bool = false
    @Published var isMuted: Bool = false
    @Published var routeName: String = ""
    @Published var isFallbackEngine: Bool = false
}
