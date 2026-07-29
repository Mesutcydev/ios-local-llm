import Foundation

// MARK: - AudioPlaybackSnapshot
// Compact playback state pulled once per CADisplayLink frame.
// Audio tap writes only RMS/peak via AudioMeterAtomics (no SwiftUI).

struct AudioPlaybackSnapshot: Sendable, Equatable {
    var generation: UInt64
    var isPlaying: Bool

    var sampleRate: Double
    /// Absolute sample on the continuous player timeline at `renderHostTime`.
    var currentPlayerSample: Int64
    /// Total samples scheduled for the current utterance generation.
    var scheduledSampleCount: Int64

    /// Host time corresponding to `currentPlayerSample`.
    var renderHostTime: UInt64
    /// Seconds from render to ear (outputLatency + I/O buffer).
    var outputPresentationLatency: Double

    var outputRMS: Float
    var outputPeak: Float

    var underrunCount: UInt64

    static let idle = AudioPlaybackSnapshot(
        generation: 0,
        isPlaying: false,
        sampleRate: 24_000,
        currentPlayerSample: 0,
        scheduledSampleCount: 0,
        renderHostTime: 0,
        outputPresentationLatency: 0,
        outputRMS: 0,
        outputPeak: 0,
        underrunCount: 0
    )
}

/// Snapshot published for the display link. Writers are MainActor / playback
/// service; readers pull once per frame.
final class AudioPlaybackSnapshotStore: @unchecked Sendable {
    static let shared = AudioPlaybackSnapshotStore()

    private let lock = NSLock()
    private var published = AudioPlaybackSnapshot.idle

    func load() -> AudioPlaybackSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    func store(_ value: AudioPlaybackSnapshot) {
        lock.lock()
        published = value
        lock.unlock()
    }

    func update(_ body: (inout AudioPlaybackSnapshot) -> Void) {
        lock.lock()
        var next = published
        body(&next)
        published = next
        lock.unlock()
    }
}
