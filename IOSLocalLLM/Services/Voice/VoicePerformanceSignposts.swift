import Foundation
import os.signpost
import QuartzCore

// MARK: - VoicePerformanceSignposts
// Points of Interest for Instruments. Cheap when disabled by OS.

enum VoicePerformanceSignposts {
    static let log = OSLog(subsystem: "com.mesutcydev.ioslocalllm.IOSLocalLLM", category: "VoicePerformance")

    static func begin(_ name: StaticString, id: OSSignpostID = .exclusive) {
        os_signpost(.begin, log: log, name: name, signpostID: id)
    }

    static func end(_ name: StaticString, id: OSSignpostID = .exclusive) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }

    static func event(_ name: StaticString, _ format: StaticString = "", _ args: CVarArg...) {
        if args.isEmpty {
            os_signpost(.event, log: log, name: name)
        } else {
            // Variadic bridging for common single-arg events.
            os_signpost(.event, log: log, name: name, "%{public}@", "\(args.first!)")
        }
    }
}

// MARK: - VoicePerformanceMonitor
// Aggregates hot-path counters. MainActor for UI-facing snapshot.

@MainActor
final class VoicePerformanceMonitor: ObservableObject {
    static let shared = VoicePerformanceMonitor()

    @Published private(set) var snapshot = VoicePerformanceSnapshot()

    private var frameWorkSamples: [Double] = []
    private var meterCount = 0
    private var progressCount = 0
    private var transcriptRebuilds = 0
    private var autoScrolls = 0
    private var windowStarted = Date()
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var droppedInWindow = 0
    private var renderedInWindow = 0
    private var firstAudioAt: Date?
    private var firstHighlightAt: Date?
    private var chunkRegisterStartedAt: Date?
    private var interruptRequestedAt: Date?
    /// Consecutive clean 1s windows after a hitch-driven downgrade.
    private var cleanWindows = 0

    private init() {}

    func resetUtterance() {
        firstAudioAt = nil
        firstHighlightAt = nil
        chunkRegisterStartedAt = nil
        interruptRequestedAt = nil
        cleanWindows = 0
        var s = snapshot
        s.firstAudioLatencyMs = 0
        s.firstHighlightLatencyMs = 0
        s.karaokeLatencyMs = 0
        s.interruptLatencyMs = 0
        s.acousticAlignmentMs = 0
        snapshot = s
    }

    func noteChunkRegisterStart() {
        chunkRegisterStartedAt = Date()
        VoicePerformanceSignposts.begin("TTSChunkRegister")
    }

    func noteFirstAudio() {
        VoicePerformanceSignposts.end("TTSChunkRegister")
        VoicePerformanceSignposts.event("FirstAudio")
        let now = Date()
        firstAudioAt = now
        if let start = chunkRegisterStartedAt {
            var s = snapshot
            s.firstAudioLatencyMs = now.timeIntervalSince(start) * 1000
            snapshot = s
        }
    }

    func noteFirstHighlight(playbackTime: TimeInterval) {
        guard firstHighlightAt == nil else { return }
        firstHighlightAt = Date()
        VoicePerformanceSignposts.event("FirstHighlight")
        if let audio = firstAudioAt, let highlight = firstHighlightAt {
            var s = snapshot
            s.firstHighlightLatencyMs = highlight.timeIntervalSince(audio) * 1000
            // Karaoke UI latency ≈ wall-clock lag vs playback clock at highlight.
            s.karaokeLatencyMs = max(0, s.firstHighlightLatencyMs - playbackTime * 1000)
            snapshot = s
        }
    }

    func noteAcousticAlignment(durationMs: Double) {
        var s = snapshot
        s.acousticAlignmentMs = durationMs
        snapshot = s
        VoicePerformanceSignposts.event("AcousticAlignmentDone")
    }

    func noteInterruptRequested() {
        interruptRequestedAt = Date()
        VoicePerformanceSignposts.begin("Interrupt")
    }

    func noteInterruptAudibleStop() {
        VoicePerformanceSignposts.end("Interrupt")
        if let start = interruptRequestedAt {
            var s = snapshot
            s.interruptLatencyMs = Date().timeIntervalSince(start) * 1000
            snapshot = s
        }
        interruptRequestedAt = nil
    }

    func noteMeterTick() {
        meterCount += 1
    }

    func noteProgressPublish() {
        progressCount += 1
    }

    func noteTranscriptRebuild() {
        transcriptRebuilds += 1
    }

    func noteAutoScroll() {
        autoScrolls += 1
    }

    /// Call once per animation frame from the orb TimelineView.
    func noteFrame(workMs: Double, vsyncInterval: CFTimeInterval = 1.0 / 60.0) {
        renderedInWindow += 1
        frameWorkSamples.append(workMs)
        if frameWorkSamples.count > 120 {
            frameWorkSamples.removeFirst(frameWorkSamples.count - 120)
        }
        let now = CACurrentMediaTime()
        if lastFrameTimestamp > 0 {
            let delta = now - lastFrameTimestamp
            if delta > vsyncInterval * 1.75 {
                droppedInWindow += Int((delta / vsyncInterval).rounded(.down)) - 1
            }
        }
        lastFrameTimestamp = now
        rollWindowIfNeeded()
    }

    func setRenderingMode(_ mode: VoiceRenderingMode) {
        var s = snapshot
        s.renderingMode = mode
        snapshot = s
    }

    private func rollWindowIfNeeded() {
        let elapsed = Date().timeIntervalSince(windowStarted)
        guard elapsed >= 1.0 else { return }
        let avg = frameWorkSamples.isEmpty
            ? 0
            : frameWorkSamples.reduce(0, +) / Double(frameWorkSamples.count)
        let maxMs = frameWorkSamples.max() ?? 0
        var s = snapshot
        s.meterEventsPerSecond = Int(Double(meterCount) / elapsed)
        s.progressEventsPerSecond = Int(Double(progressCount) / elapsed)
        s.transcriptRebuildsPerSecond = Int(Double(transcriptRebuilds) / elapsed)
        s.autoScrollsPerSecond = Int(Double(autoScrolls) / elapsed)
        s.averageFrameWorkMs = avg
        s.maximumFrameWorkMs = maxMs
        s.renderedFrames += renderedInWindow
        s.droppedFrames += max(0, droppedInWindow)
        snapshot = s

        // Temporary hitch cap: downgrade under load, then restore after a few
        // clean windows. Never permanently stick `.reduced` for the session —
        // that made the orb look broken after one bad second.
        let preferred = VoiceSettingsStore.shared.renderingMode
        // Only count real vsync drops. `averageFrameWorkMs` comes from a
        // SwiftUI probe that does not measure Canvas GPU cost and was
        // falsely pinning the orb in `.reduced`.
        let hitching = droppedInWindow >= 10
        if hitching {
            cleanWindows = 0
            if preferred == .automatic || preferred == .full,
               SpeechPlaybackCoordinator.shared.orb.renderingMode != .reduced {
                s.renderingMode = .reduced
                snapshot = s
                SpeechPlaybackCoordinator.shared.orb.renderingMode = .reduced
            }
        } else {
            cleanWindows += 1
            if cleanWindows >= 3,
               SpeechPlaybackCoordinator.shared.orb.renderingMode == .reduced,
               preferred != .reduced {
                s.renderingMode = preferred
                snapshot = s
                SpeechPlaybackCoordinator.shared.orb.renderingMode = preferred
                cleanWindows = 0
            }
        }

        meterCount = 0
        progressCount = 0
        transcriptRebuilds = 0
        autoScrolls = 0
        renderedInWindow = 0
        droppedInWindow = 0
        windowStarted = Date()
    }
}
