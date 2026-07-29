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
    /// Spoken cursor advances every display tick — NOT `@Published`.
    /// Publishing it rebuilt VoiceConversationView at 30–60 Hz and made the
    /// screen visibly flutter. Karaoke UI polls this via a capped TimelineView.
    private(set) var spokenUTF16End: Int = 0
    @Published var timingSource: SpeechAlignmentAccuracy?
    @Published var alignmentDetail: String?

    func setSpokenUTF16End(_ value: Int) {
        spokenUTF16End = value
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
