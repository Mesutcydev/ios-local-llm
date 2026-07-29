import OSLog

/// Debug-build signpost instrumentation for latency measurement.
///
/// Intervals:
/// - `StateChangeToRender`: voice state change to orb state update.
/// - `AudioSubmitToPublish`: audio callback to normalized published level.
/// - `PlaybackStartToSpeaking`: TTS playback-start callback to speaking visuals.
/// - `InterruptToVisualStop`: playback interruption to visual stop.
///
/// All entry points compile to no-ops in release builds.
public enum VoiceOrbSignpost {
    public static let subsystem = "com.localaistudio.voiceorb"

    private static let poster = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    public static func begin(_ name: StaticString, id: OSSignpostID = .exclusive) -> OSSignpostIntervalState? {
        #if DEBUG
        return poster.beginInterval(name, id: id)
        #else
        return nil
        #endif
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        #if DEBUG
        if let state { poster.endInterval(name, state) }
        #endif
    }

    public static func event(_ name: StaticString) {
        #if DEBUG
        poster.emitEvent(name)
        #endif
    }
}
