import Foundation

// MARK: - Voice rendering mode
// Automatic adapts when sustained frame drops are detected.

enum VoiceRenderingMode: String, Sendable, Equatable, CaseIterable {
    case automatic
    case full
    case reduced
}

// MARK: - VoicePerformanceSnapshot
// DEBUG / Instruments-facing counters for Voice Mode hot-path health.

struct VoicePerformanceSnapshot: Sendable, Equatable {
    var renderedFrames: Int = 0
    var droppedFrames: Int = 0
    var meterEventsPerSecond: Int = 0
    var progressEventsPerSecond: Int = 0
    var transcriptRebuildsPerSecond: Int = 0
    var autoScrollsPerSecond: Int = 0
    var averageFrameWorkMs: Double = 0
    var maximumFrameWorkMs: Double = 0
    var karaokeLatencyMs: Double = 0
    var firstAudioLatencyMs: Double = 0
    var firstHighlightLatencyMs: Double = 0
    var interruptLatencyMs: Double = 0
    var acousticAlignmentMs: Double = 0
    var renderingMode: VoiceRenderingMode = .automatic
}
