import AVFoundation
import Foundation
import QuartzCore

// MARK: - AudioVisualClock
// Pure conversion: player sample timeline + display target host time +
// output presentation latency → the sample the user will hear.

enum AudioVisualClock {
    /// Sample that should be highlighted / drive the orb for a display frame.
    ///
    /// `displayed = playerSample + Δ(renderHost → targetHost) * sr − latencySamples`
    static func displayedSample(
        snapshot: AudioPlaybackSnapshot,
        targetHostTime: UInt64
    ) -> Int64 {
        guard snapshot.isPlaying || snapshot.currentPlayerSample > 0 else { return 0 }
        let sr = max(1, snapshot.sampleRate)

        var sample = snapshot.currentPlayerSample
        if snapshot.renderHostTime != 0, targetHostTime != 0 {
            let renderSeconds = AVAudioTime.seconds(forHostTime: snapshot.renderHostTime)
            let targetSeconds = AVAudioTime.seconds(forHostTime: targetHostTime)
            let delta = targetSeconds - renderSeconds
            if delta.isFinite {
                sample += Int64((delta * sr).rounded())
            }
        }

        let latencySamples = Int64((snapshot.outputPresentationLatency * sr).rounded())
        sample -= latencySamples

        let maxSample = max(0, snapshot.scheduledSampleCount)
        if sample < 0 { return 0 }
        if maxSample > 0, sample > maxSample { return maxSample }
        return sample
    }

    static func displayedSeconds(
        snapshot: AudioPlaybackSnapshot,
        targetHostTime: UInt64
    ) -> TimeInterval {
        let sr = max(1, snapshot.sampleRate)
        return Double(displayedSample(snapshot: snapshot, targetHostTime: targetHostTime)) / sr
    }

    /// Host time for the frame currently being prepared by CADisplayLink.
    static func hostTime(forDisplayTimestamp timestamp: CFTimeInterval) -> UInt64 {
        // CACurrentMediaTime and mach absolute time share the same continuous
        // timeline used by AVAudioTime host times on Apple platforms.
        let nowMedia = CACurrentMediaTime()
        let nowHost = AVAudioTime.hostTime(forSeconds: nowMedia)
        let delta = timestamp - nowMedia
        if !delta.isFinite { return nowHost }
        return AVAudioTime.hostTime(forSeconds: nowMedia + delta)
    }

    /// Session output latency + I/O buffer duration (seconds).
    static func currentOutputPresentationLatency() -> TimeInterval {
        let session = AVAudioSession.sharedInstance()
        let output = max(0, session.outputLatency)
        let buffer = max(0, session.ioBufferDuration)
        return output + buffer
    }
}
