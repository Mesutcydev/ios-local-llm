import Foundation

// MARK: - VoiceSessionPhase
// UI-facing session phase for Voice Mode. Broader than the conversation
// service's turn-taking Phase so the orb / transcript can express preparing,
// paused, and interrupted without overloading the VAD state machine.

enum VoiceSessionPhase: Equatable, Sendable {
    case idle
    case listening
    /// Confirmed user speech onset while still in the listening turn.
    /// Drives orb speechDetected animations without changing turn-taking.
    case speechDetected
    case thinking
    case preparingSpeech
    case speaking
    case paused
    case interrupted
    case failed(String)

    var statusLabel: String {
        switch self {
        case .idle: return "Ready"
        case .listening, .speechDetected: return "Listening"
        case .thinking: return "Thinking"
        case .preparingSpeech: return "Preparing voice"
        case .speaking: return "Speaking"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .failed: return "Error"
        }
    }
}

// MARK: - Speech timing

struct SpeechWordTiming: Identifiable, Equatable, Sendable {
    let id: UUID
    let word: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// UTF-16 offsets into the parent segment / transcript string.
    let utf16Range: NSRange

    init(
        id: UUID = UUID(),
        word: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        utf16Range: NSRange
    ) {
        self.id = id
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.utf16Range = utf16Range
    }
}

struct SpeechSegment: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let words: [SpeechWordTiming]
    let timingSource: SpeechAlignmentAccuracy

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        words: [SpeechWordTiming],
        timingSource: SpeechAlignmentAccuracy
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.words = words
        self.timingSource = timingSource
    }
}

/// Compatibility alias — prefer `SpeechAlignmentAccuracy`.
typealias SpeechTimingSource = SpeechAlignmentAccuracy

// MARK: - Playback snapshot

struct VoicePlaybackSnapshot: Equatable, Sendable {
    var phase: VoiceSessionPhase
    var currentTime: TimeInterval
    var duration: TimeInterval
    var normalizedLevel: Float
    var activeWordIndex: Int?
    var activeSegmentIndex: Int?
    var spokenUTF16End: Int
    var activeUTF16Range: NSRange?
    var isMuted: Bool
    var canInterrupt: Bool
    var canPauseResume: Bool
    var isFallbackEngine: Bool
    var timingSource: SpeechAlignmentAccuracy?
    var alignmentDetail: String?
    /// Active highlight may span multiple short words (phrase group).
    var activePhraseUTF16Range: NSRange?

    static let idle = VoicePlaybackSnapshot(
        phase: .idle,
        currentTime: 0,
        duration: 0,
        normalizedLevel: 0,
        activeWordIndex: nil,
        activeSegmentIndex: nil,
        spokenUTF16End: 0,
        activeUTF16Range: nil,
        isMuted: false,
        canInterrupt: false,
        canPauseResume: false,
        isFallbackEngine: false,
        timingSource: nil,
        alignmentDetail: nil,
        activePhraseUTF16Range: nil
    )

    var playbackProgress: Double {
        guard duration > 0.001 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }
}

// MARK: - Engine capabilities

struct TTSEngineCapabilities: OptionSet, Sendable, Equatable {
    let rawValue: Int

    static let streamingAudio = Self(rawValue: 1 << 0)
    static let exactWordTimings = Self(rawValue: 1 << 1)
    static let playbackMetering = Self(rawValue: 1 << 2)
    static let pauseResume = Self(rawValue: 1 << 3)
    static let immediateCancellation = Self(rawValue: 1 << 4)
    static let completePCMBuffers = Self(rawValue: 1 << 5)
    /// Per-token predicted duration frames (e.g. Kitten CoreML `pred_dur`).
    static let engineDerivedDurations = Self(rawValue: 1 << 6)

    static func capabilities(for kind: VoiceEngineKind) -> TTSEngineCapabilities {
        switch kind {
        case .appleSystem:
            // Offline CAF render → PCM. No willSpeakRange callbacks on the
            // live synthesizer path (that path was removed to fix zombie voice).
            return [.completePCMBuffers, .playbackMetering, .immediateCancellation]
        case .kittenTTS:
            // CoreML path exposes `pred_dur`; ONNX path does not request it.
            return [
                .completePCMBuffers,
                .playbackMetering,
                .immediateCancellation,
                .engineDerivedDurations
            ]
        case .kokoro:
            // Duration stage is fused inside the CoreML graph — not exposed.
            return [.completePCMBuffers, .playbackMetering, .immediateCancellation]
        }
    }
}
