import Foundation
import QuartzCore
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Level processor (pure DSP, fully testable)

/// Deterministic RMS → display-level pipeline.
///
/// Pure value type with explicit `dt` so tests are reproducible and the DSP
/// can run off the main actor if needed. Performs, in order:
/// input clamping → noise-floor removal → perceptual (log) normalization →
/// fast-attack / slow-release smoothing → spike protection → silence gating.
public struct VoiceOrbLevelProcessor: Sendable, Equatable {

    /// RMS below this is treated as room noise and subtracted.
    public var noiseFloor: Float
    /// Normalized level below this (and falling) is snapped to silence.
    public var silenceGateThreshold: Float
    /// Gain of the perceptual curve `log(1+g·x)/log(1+g)`.
    public var perceptualGain: Float
    /// Time constant for rising edges (fast: speech attacks feel immediate).
    public var attackTime: Float
    /// Time constant for falling edges (slower: release feels smooth).
    public var releaseTime: Float
    /// Absolute cap on a single update's rise — spike protection. Generous
    /// enough to never slow normal attack envelopes (≈0.28 for a full-scale
    /// hit at 120 Hz), tight enough to absorb absurd single-sample jumps
    /// (e.g. the first sample after a long pause).
    public var maxStepPerUpdate: Float

    public private(set) var level: Float = 0

    public init(
        noiseFloor: Float = 0.02,
        silenceGateThreshold: Float = 0.015,
        perceptualGain: Float = 6,
        attackTime: Float = 0.06,
        releaseTime: Float = 0.28,
        maxStepPerUpdate: Float = 0.5
    ) {
        self.noiseFloor = noiseFloor
        self.silenceGateThreshold = silenceGateThreshold
        self.perceptualGain = perceptualGain
        self.attackTime = attackTime
        self.releaseTime = releaseTime
        self.maxStepPerUpdate = maxStepPerUpdate
    }

    public mutating func reset() {
        level = 0
    }

    /// Clamps, removes the noise floor and applies perceptual normalization.
    public static func normalize(_ rms: Float, noiseFloor: Float, gain: Float) -> Float {
        guard rms.isFinite else { return 0 }
        let clamped = min(max(rms, 0), 1)
        let floor = min(max(noiseFloor, 0), 0.9)
        let floored = max(clamped - floor, 0) / (1 - floor)
        let g = max(gain, 0.0001)
        return log(1 + g * floored) / log(1 + g)
    }

    /// Advances the smoother with one sample. `dt` in seconds (clamped ≥ 0).
    @discardableResult
    public mutating func process(_ rms: Float, dt: Float) -> Float {
        let target = Self.normalize(rms, noiseFloor: noiseFloor, gain: perceptualGain)
        let dt = max(dt.isFinite ? dt : 0, 0)

        var next: Float
        if target >= level {
            // Fast attack.
            let a = 1 - exp(-dt / max(attackTime, Float.ulpOfOne))
            next = level + (target - level) * a
            // Spike protection: cap absolute single-step rise.
            next = min(next, level + maxStepPerUpdate)
        } else {
            // Slower release.
            let a = 1 - exp(-dt / max(releaseTime, Float.ulpOfOne))
            next = level + (target - level) * a
        }

        // Silence gate: snap to zero instead of hovering near the noise floor.
        if target < silenceGateThreshold, next < silenceGateThreshold * 2 {
            next = 0
        }

        level = min(max(next.isFinite ? next : 0, 0), 1)
        return level
    }
}

// MARK: - Audio model (MainActor, throttled publishing)

/// Shared audio-level model for microphone input and speech output.
///
/// Raw audio taps call ``submitMicrophoneRMS(_:)`` / ``submitOutputRMS(_:)``
/// with normalized `0...1` RMS values. Processing runs immediately (O(1) per
/// sample, no allocations), but `@Published` updates are coalesced to the
/// active display rate so SwiftUI never receives one update per audio buffer.
@MainActor
public final class VoiceOrbAudioModel: ObservableObject {

    @Published public private(set) var microphoneLevel: CGFloat = 0
    @Published public private(set) var outputLevel: CGFloat = 0
    /// Smoothed "voice is present" signal derived from the microphone.
    @Published public private(set) var speechActivity: CGFloat = 0

    /// Minimum interval between published display updates. Defaults to 120 Hz
    /// for ProMotion; raise it (e.g. `1.0/60`) on constrained tiers.
    public var minimumPublishInterval: TimeInterval = 1.0 / 120.0

    /// Injectable clock for tests.
    var now: @Sendable () -> TimeInterval = CACurrentMediaTime

    private var micProcessor = VoiceOrbLevelProcessor()
    private var outputProcessor = VoiceOrbLevelProcessor(attackTime: 0.05, releaseTime: 0.22)
    private var activityProcessor = VoiceOrbLevelProcessor(attackTime: 0.09, releaseTime: 0.45)

    private var lastMicSampleAt: TimeInterval?
    private var lastOutputSampleAt: TimeInterval?

    private var lastMicPublishAt: TimeInterval = -.infinity
    private var lastOutputPublishAt: TimeInterval = -.infinity

    private var pendingMic: Float?
    private var pendingOutput: Float?

    /// Single coalescing flush task; replaced (never stacked) when new
    /// samples arrive while throttled.
    private var flushTask: Task<Void, Never>?
    /// Monotonic token so a delayed flush can never re-publish stale values
    /// after ``reset()``.
    private var generation: UInt64 = 0

    public init() {}

    deinit {
        flushTask?.cancel()
    }

    // MARK: Submissions

    /// Submit a normalized microphone RMS sample (`0...1`).
    public func submitMicrophoneRMS(_ rms: Float) {
        let t = now()
        let dt = Float(lastMicSampleAt.map { t - $0 } ?? (1.0 / 120.0))
        lastMicSampleAt = t

        let level = micProcessor.process(rms, dt: dt)
        let activity = activityProcessor.process(rms, dt: dt)

        publish(mic: level, activity: activity, at: t)
    }

    /// Submit a normalized playback (TTS output) RMS sample (`0...1`).
    public func submitOutputRMS(_ rms: Float) {
        let t = now()
        let dt = Float(lastOutputSampleAt.map { t - $0 } ?? (1.0 / 120.0))
        lastOutputSampleAt = t

        let level = outputProcessor.process(rms, dt: dt)
        publish(output: level, at: t)
    }

    /// Zeroes all levels and cancels any pending throttled publish, so a
    /// delayed flush can never reactivate an obsolete value (interruption).
    public func reset() {
        generation &+= 1
        flushTask?.cancel()
        flushTask = nil
        pendingMic = nil
        pendingOutput = nil
        micProcessor.reset()
        outputProcessor.reset()
        activityProcessor.reset()
        lastMicSampleAt = nil
        lastOutputSampleAt = nil
        if microphoneLevel != 0 { microphoneLevel = 0 }
        if outputLevel != 0 { outputLevel = 0 }
        if speechActivity != 0 { speechActivity = 0 }
    }

    // MARK: Throttled publishing

    private func publish(mic: Float, activity: Float, at t: TimeInterval) {
        if t - lastMicPublishAt >= minimumPublishInterval {
            lastMicPublishAt = t
            microphoneLevel = CGFloat(level: mic)
            speechActivity = CGFloat(level: activity)
            pendingMic = nil
        } else {
            pendingMic = mic
            scheduleFlush(deadline: lastMicPublishAt + minimumPublishInterval)
        }
    }

    private func publish(output: Float, at t: TimeInterval) {
        if t - lastOutputPublishAt >= minimumPublishInterval {
            lastOutputPublishAt = t
            outputLevel = CGFloat(level: output)
            pendingOutput = nil
        } else {
            pendingOutput = output
            scheduleFlush(deadline: lastOutputPublishAt + minimumPublishInterval)
        }
    }

    private func scheduleFlush(deadline: TimeInterval) {
        guard flushTask == nil else { return }
        let delay = max(deadline - now(), 0)
        let token = generation
        flushTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == token else { return }
                self.flushPending()
            }
        }
    }

    private func flushPending() {
        flushTask = nil
        let t = now()
        if let mic = pendingMic {
            pendingMic = nil
            lastMicPublishAt = t
            microphoneLevel = CGFloat(level: mic)
            speechActivity = CGFloat(level: activityProcessor.level)
        }
        if let out = pendingOutput {
            pendingOutput = nil
            lastOutputPublishAt = t
            outputLevel = CGFloat(level: out)
        }
    }

    // MARK: Test introspection

    /// `true` while a throttled flush is scheduled. Used by the stress test to
    /// prove no delayed work survives a reset or rapid state changes.
    var hasPendingFlush: Bool { flushTask != nil }
}

// MARK: - RMS helper

#if canImport(AVFoundation)
public enum VoiceOrbRMS {
    /// Normalized RMS (`0...1`) of an `AVAudioPCMBuffer`, suitable for
    /// ``VoiceOrbAudioModel/submitMicrophoneRMS(_:)`` or
    /// ``submitOutputRMS(_:)`` from an audio tap. Safe to call on a real-time
    /// audio thread: no locks, no allocations.
    public static func compute(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        let samples = channelData[0]
        var sum: Float = 0
        var i = 0
        // Unrolled by 4 for a modest speedup on long buffers.
        while i + 4 <= frameLength {
            let a = samples[i], b = samples[i + 1], c = samples[i + 2], d = samples[i + 3]
            sum += a * a + b * b + c * c + d * d
            i += 4
        }
        while i < frameLength {
            let s = samples[i]
            sum += s * s
            i += 1
        }
        let rms = sqrt(sum / Float(frameLength))
        return min(max(rms.isFinite ? rms : 0, 0), 1)
    }
}
#endif

private extension CGFloat {
    init(level: Float) {
        let clamped = Swift.min(Swift.max(level, 0), 1)
        self = CGFloat(clamped)
    }
}
