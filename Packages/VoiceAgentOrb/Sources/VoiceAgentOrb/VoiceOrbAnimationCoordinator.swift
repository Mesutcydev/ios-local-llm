import Foundation

/// A single immutable description of everything the renderer needs for one
/// frame. Computed by ``VoiceOrbAnimationCoordinator`` from continuous time,
/// the active transition and the latest audio levels.
public struct VoiceOrbFrameSnapshot: Sendable, Equatable {
    public var stateKind: VoiceOrbStateKind
    public var config: VoiceOrbVisualConfiguration
    /// Continuous clock time (seconds, monotonic).
    public var time: Double
    /// Breathing scale, e.g. `0.985...1.015` while idle.
    public var breathingScale: Double
    /// Base rotation angle for internal fields (radians).
    public var rotation: Double
    /// Effective microphone level after state reactivity gating. `0...1`.
    public var micLevel: Double
    /// Effective playback level. Hard-gated to zero on interruption. `0...1`.
    public var outputLevel: Double
    /// Voice-present signal for absorbing/edge emphasis. `0...1`.
    public var speechActivity: Double
    /// Clamped model-loading progress. `0...1`.
    public var loadingProgress: Double
    /// Thinking: 0 → 1 → 0 condense/release pulse of the core. `0...1`.
    public var condensePulse: Double
    /// Error: brief one-shot warm pulse, decays to 0. `0...1`.
    public var errorPulse: Double
    /// Interruption: 1 right after the cut, decays to 0 while settling.
    public var interruptSettle: Double
    public var reducedMotion: Bool

    public init(
        stateKind: VoiceOrbStateKind,
        config: VoiceOrbVisualConfiguration,
        time: Double,
        breathingScale: Double,
        rotation: Double,
        micLevel: Double,
        outputLevel: Double,
        speechActivity: Double,
        loadingProgress: Double,
        condensePulse: Double,
        errorPulse: Double,
        interruptSettle: Double,
        reducedMotion: Bool
    ) {
        self.stateKind = stateKind
        self.config = config
        self.time = time
        self.breathingScale = breathingScale
        self.rotation = rotation
        self.micLevel = micLevel
        self.outputLevel = outputLevel
        self.speechActivity = speechActivity
        self.loadingProgress = loadingProgress
        self.condensePulse = condensePulse
        self.errorPulse = errorPulse
        self.interruptSettle = interruptSettle
        self.reducedMotion = reducedMotion
    }
}

/// Owns the orb's single animation clock semantics: interruptible state
/// transitions, breathing/rotation phases, audio-reactive gating, loading
/// progress and one-shot pulses (error, interruption).
///
/// The coordinator is deliberately *stateless about animation*: it stores
/// transition anchors, and derives every phase from the continuous clock the
/// view passes in. Nothing here schedules timers or tasks, so there is no
/// delayed mutation that could reactivate an obsolete animation.
@MainActor
public final class VoiceOrbAnimationCoordinator: ObservableObject {

    @Published public private(set) var state: VoiceOrbState = .idle

    /// Respect Reduce Motion: strips oscillating motion from configurations
    /// and shortens transitions to simple crossfades.
    public var reducedMotion: Bool = false

    // Transition anchors. The *displayed* configuration is always
    // `from.lerp(to, eased(t))`, so capturing `configuration(at:)` mid-blend
    // makes every transition interruptible by construction.
    private var transitionFrom: VoiceOrbVisualConfiguration
    private var transitionTo: VoiceOrbVisualConfiguration
    private var transitionStart: Double = 0
    private var transitionDuration: Double = 0.3

    /// Monotonic token; incremented on every state change. Available for
    /// hosts/tests that need to cancel delayed work tied to a state.
    public private(set) var transitionGeneration: UInt64 = 0

    // One-shot pulses.
    private var interruptAt: Double?
    private var errorAt: Double?

    /// When the speaking waves were hard-cut (interruption), the output level
    /// gate stays at zero until a non-interrupted state is entered.
    private var outputGateOpen: Bool = false

    /// Clamped `0...1` model loading progress.
    public private(set) var loadingProgress: Double = 0

    /// Timestamp of the last state change (for signpost measurement).
    private var lastStateChangeAt: Double = 0

    // Palette crossfade anchors (colors fade faster than the motion blend).
    private var paletteFrom: VoiceOrbStateKind = .idle
    private var paletteTo: VoiceOrbStateKind = .idle
    private var paletteStart: Double = 0
    private let paletteFadeDuration: Double = 0.22

    public init(reducedMotion: Bool = false) {
        self.reducedMotion = reducedMotion
        let idle = VoiceOrbVisualConfiguration.configuration(for: .idle, reducedMotion: reducedMotion)
        transitionFrom = idle
        transitionTo = idle
    }

    // MARK: State changes

    /// Accepts a new state immediately, mid-transition if needed.
    /// Never waits for the current animation to finish.
    public func setState(_ newState: VoiceOrbState, now: Double) {
        let oldState = state

        // Progress-only updates (still `.preparing`) don't restart a blend.
        if newState.kind == oldState.kind, case .preparing = newState {
            loadingProgress = Self.clamp01(newState.normalizedProgress ?? loadingProgress)
            state = newState
            return
        }
        guard newState != oldState else { return }

        // Capture exactly what is on screen right now as the blend origin.
        let current = configuration(at: now)

        transitionFrom = current
        transitionTo = VoiceOrbVisualConfiguration.configuration(
            for: newState, reducedMotion: reducedMotion
        )
        transitionStart = now
        transitionDuration = reducedMotion
            ? 0.18
            : VoiceOrbTransitionTiming.duration(from: oldState.kind, to: newState.kind)
        transitionGeneration &+= 1
        lastStateChangeAt = now

        switch newState.kind {
        case .interrupted:
            // Hard-cut outward waves and playback reactivity *now*, not at the
            // end of the blend: speaking must stop within a frame or two.
            transitionFrom.waveAmplitude = 0
            transitionFrom.outputReactivity = 0
            outputGateOpen = false
            interruptAt = now
            VoiceOrbSignpost.event("Interrupt visual stop")
        case .error:
            errorAt = now
            outputGateOpen = false
        case .speaking:
            // Waves are driven by the real output level which only flows once
            // playback actually started, so this flag just re-arms the gate.
            outputGateOpen = true
        case .preparing:
            loadingProgress = Self.clamp01(newState.normalizedProgress ?? 0)
            outputGateOpen = false
        default:
            outputGateOpen = false
        }

        if newState.kind != .interrupted {
            interruptAt = nil
        }
        if newState.kind != .error {
            errorAt = nil
        }

        paletteFrom = oldState.kind
        paletteTo = newState.kind
        paletteStart = now

        state = newState
        VoiceOrbSignpost.event("Orb state applied")
    }

    /// Current palette crossfade: from-kind, to-kind and progress `0...1`.
    public func paletteBlend(at now: Double) -> (from: VoiceOrbStateKind, to: VoiceOrbStateKind, t: Double) {
        let raw = (now - paletteStart) / max(paletteFadeDuration, .ulpOfOne)
        return (paletteFrom, paletteTo, min(max(raw, 0), 1))
    }

    /// Updates Reduce Motion without a state change: re-targets the current
    /// configuration with a short crossfade, staying interruptible.
    public func setReducedMotion(_ flag: Bool, now: Double) {
        guard flag != reducedMotion else { return }
        reducedMotion = flag
        let current = configuration(at: now)
        transitionFrom = current
        transitionTo = VoiceOrbVisualConfiguration.configuration(for: state, reducedMotion: flag)
        transitionStart = now
        transitionDuration = 0.18
        transitionGeneration &+= 1
    }

    /// Convenience for hosts that hold a generation token: applies `state`
    /// only if no newer state arrived since the token was taken — protects
    /// against delayed callbacks reactivating obsolete states.
    public func setState(_ newState: VoiceOrbState, now: Double, ifCurrentGeneration generation: UInt64) {
        guard generation == transitionGeneration else { return }
        setState(newState, now: now)
    }

    // MARK: Frame values

    /// The displayed visual configuration at time `now`, blending the two
    /// transition anchors with an ease-in-out curve.
    public func configuration(at now: Double) -> VoiceOrbVisualConfiguration {
        let raw = (now - transitionStart) / max(transitionDuration, .ulpOfOne)
        let t = Self.easeInOut(min(max(raw, 0), 1))
        return transitionFrom.lerp(to: transitionTo, t: t)
    }

    /// Computes the immutable frame snapshot consumed by the renderer.
    public func snapshot(
        at now: Double,
        microphoneLevel: Double,
        outputLevel: Double,
        speechActivity: Double
    ) -> VoiceOrbFrameSnapshot {
        let config = configuration(at: now)

        // Breathing: slow sine, amplitude from the blended configuration.
        let breathingScale: Double
        if reducedMotion || config.breathingAmplitude <= 0 {
            breathingScale = 1
        } else {
            breathingScale = 1 + config.breathingAmplitude * sin(now * 2 * .pi / 5.5)
        }

        let rotation = now * VoiceOrbEnergyField.baseSpeed * config.rotationSpeed

        // Audio reactivity is gated by the state's configuration, so e.g.
        // transcribing barely reacts to the microphone.
        let mic = Self.clamp01(microphoneLevel) * config.micReactivity
        let out = outputGateOpen
            ? Self.clamp01(outputLevel) * config.outputReactivity
            : 0
        let activity = Self.clamp01(speechActivity) * config.inwardPull

        // One-shot pulses.
        let settle = Self.decay(since: interruptAt, now: now, duration: 0.45)
        let errorPulse = Self.decay(since: errorAt, now: now, duration: 0.60)

        // Thinking condense/release: slow asymmetric pulse, phase-offset so it
        // reads as occasional rather than metronomic.
        let condense: Double
        if config.condensePulse > 0.01, !reducedMotion {
            let phase = now * 2 * .pi / 4.2 + 1.3
            let shaped = pow(0.5 + 0.5 * sin(phase), 2.2)
            condense = shaped * config.condensePulse
        } else {
            condense = 0
        }

        return VoiceOrbFrameSnapshot(
            stateKind: state.kind,
            config: config,
            time: now,
            breathingScale: breathingScale,
            rotation: rotation,
            micLevel: mic,
            outputLevel: out,
            speechActivity: activity,
            loadingProgress: loadingProgress,
            condensePulse: condense,
            errorPulse: errorPulse,
            interruptSettle: settle,
            reducedMotion: reducedMotion
        )
    }

    /// Full reset of phases/pulses (e.g. session torn down).
    public func reset(now: Double) {
        interruptAt = nil
        errorAt = nil
        loadingProgress = 0
        outputGateOpen = false
        let config = VoiceOrbVisualConfiguration.configuration(for: state, reducedMotion: reducedMotion)
        transitionFrom = config
        transitionTo = config
        transitionStart = now
        transitionDuration = 0.2
        transitionGeneration &+= 1
    }

    // MARK: Helpers

    static func clamp01(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return min(max(x, 0), 1)
    }

    static func easeInOut(_ t: Double) -> Double {
        t * t * (3 - 2 * t)
    }

    /// 1 at `since`, decaying smoothly to 0 over `duration` seconds.
    static func decay(since: Double?, now: Double, duration: Double) -> Double {
        guard let since else { return 0 }
        let raw = (now - since) / max(duration, .ulpOfOne)
        let t = min(max(raw, 0), 1)
        return 1 - easeInOut(t)
    }
}
