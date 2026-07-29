import AVFoundation
import Foundation

// MARK: - Alignment accuracy
// Capability ladder for karaoke. Never label estimated timing as exact.

enum SpeechAlignmentAccuracy: String, Sendable, Equatable {
    case exact
    case engineDerived
    case acousticallyAligned
    case estimated
    case phraseLevel

    var diagnosticLabel: String {
        switch self {
        case .exact: return "Exact"
        case .engineDerived: return "Engine-derived"
        case .acousticallyAligned: return "Acoustically aligned"
        case .estimated: return "Estimated"
        case .phraseLevel: return "Phrase-level"
        }
    }
}

struct SpeechAlignmentResult: Sendable, Equatable {
    let segments: [SpeechSegment]
    let accuracy: SpeechAlignmentAccuracy
    /// Optional note for DEBUG overlays (e.g. "Kitten pred_dur").
    let diagnosticDetail: String?

    init(
        segments: [SpeechSegment],
        accuracy: SpeechAlignmentAccuracy,
        diagnosticDetail: String? = nil
    ) {
        self.segments = segments
        self.accuracy = accuracy
        self.diagnosticDetail = diagnosticDetail
    }

    static let empty = SpeechAlignmentResult(segments: [], accuracy: .estimated)
}

/// Optional synthesis-side metadata used by alignment providers.
struct SynthesisMetadata: Sendable, Equatable {
    var phonemeIDs: [Int32]? = nil
    var predictedDurationsFrames: [Float]? = nil
    var validTokenCount: Int? = nil
    var samplesPerFrame: Double? = nil
    var sourceText: String? = nil
    var engineKind: VoiceEngineKind? = nil
}

protocol SpeechAlignmentProvider: Sendable {
    func align(
        text: String,
        audio: AVAudioPCMBuffer,
        synthesisMetadata: SynthesisMetadata?,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int
    ) async -> SpeechAlignmentResult
}
