import Foundation

// MARK: - Public state

/// The voice-session states the orb can visualize.
///
/// The orb never owns session logic; the host app maps its pipeline state onto
/// these values and the orb renders them.
public enum VoiceOrbState: Equatable, Sendable {
    case idle
    case preparing(progress: Double?)
    case listening
    case speechDetected
    case transcribing
    case thinking
    case speaking
    case interrupted
    case error(message: String?)
    case disabled

    /// Normalized `0...1` progress for `.preparing`, clamped defensively.
    /// `nil` for every other state or when progress is unknown.
    public var normalizedProgress: Double? {
        guard case let .preparing(progress) = self, let progress, progress.isFinite else { return nil }
        return min(max(progress, 0), 1)
    }

    /// Broad category used for palette lookup, transition timing and accessibility.
    public var kind: VoiceOrbStateKind {
        switch self {
        case .idle: return .idle
        case .preparing: return .preparing
        case .listening: return .listening
        case .speechDetected: return .speechDetected
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .interrupted: return .interrupted
        case .error: return .error
        case .disabled: return .disabled
        }
    }
}

/// Semantic identity of a ``VoiceOrbState`` without associated values.
public enum VoiceOrbStateKind: String, Sendable, CaseIterable {
    case idle
    case preparing
    case listening
    case speechDetected
    case transcribing
    case thinking
    case speaking
    case interrupted
    case error
    case disabled
}

// MARK: - Visual configuration

/// Fully interpolatable description of how the orb looks at a given moment.
///
/// Every field is a `Double` so state transitions can blend any two
/// configurations mid-flight, which is what makes transitions interruptible.
/// Produces values via ``configuration(for:reducedMotion:)``.
public struct VoiceOrbVisualConfiguration: Equatable, Sendable {
    /// Overall internal energy brightness/violence. `0...1`.
    public var energy: Double
    /// Strength of the outer atmospheric glow. `0...1`.
    public var glow: Double
    /// Brightness of the central intelligence core. `0...1`.
    public var coreBrightness: Double
    /// Edge/rim light intensity. `0...1`.
    public var rimIntensity: Double
    /// Breathing scale amplitude. Idle uses ≈0.015 (scale 0.985...1.015).
    public var breathingAmplitude: Double
    /// Multiplier on the slow internal rotation. `1` = base speed.
    public var rotationSpeed: Double
    /// Outward travelling wave rings driven by TTS output (speaking). `0...1`.
    public var waveAmplitude: Double
    /// Inward absorption pull driven by the microphone (listening). `0...1`.
    public var inwardPull: Double
    /// Asymmetric surface deformation. `0...1`.
    public var deformation: Double
    /// Visibility of fine interior particles. `0...1`.
    public var particleVisibility: Double
    /// Additional shell scale beyond breathing (alert expansion). ≈`0...0.08`.
    public var shellExpansion: Double
    /// Focused rotating band used while transcribing. `0...1`.
    public var focusBandIntensity: Double
    /// Periodic core condense/release pulse used while thinking. `0...1`.
    public var condensePulse: Double
    /// Circumference progress light used while preparing. `0...1`.
    public var progressGlow: Double
    /// How strongly the microphone level displaces the surface. `0...1`.
    public var micReactivity: Double
    /// How strongly playback level drives brightness/waves. `0...1`.
    public var outputReactivity: Double
    /// Global dimming applied on top (error settle / disabled). `0...1`.
    public var dimming: Double

    public init(
        energy: Double,
        glow: Double,
        coreBrightness: Double,
        rimIntensity: Double,
        breathingAmplitude: Double,
        rotationSpeed: Double,
        waveAmplitude: Double,
        inwardPull: Double,
        deformation: Double,
        particleVisibility: Double,
        shellExpansion: Double,
        focusBandIntensity: Double,
        condensePulse: Double,
        progressGlow: Double,
        micReactivity: Double,
        outputReactivity: Double,
        dimming: Double
    ) {
        self.energy = energy
        self.glow = glow
        self.coreBrightness = coreBrightness
        self.rimIntensity = rimIntensity
        self.breathingAmplitude = breathingAmplitude
        self.rotationSpeed = rotationSpeed
        self.waveAmplitude = waveAmplitude
        self.inwardPull = inwardPull
        self.deformation = deformation
        self.particleVisibility = particleVisibility
        self.shellExpansion = shellExpansion
        self.focusBandIntensity = focusBandIntensity
        self.condensePulse = condensePulse
        self.progressGlow = progressGlow
        self.micReactivity = micReactivity
        self.outputReactivity = outputReactivity
        self.dimming = dimming
    }

    /// Linear interpolation of every channel; used for interruptible blending.
    public func lerp(to other: VoiceOrbVisualConfiguration, t: Double) -> VoiceOrbVisualConfiguration {
        let t = min(max(t, 0), 1)
        func l(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return VoiceOrbVisualConfiguration(
            energy: l(energy, other.energy),
            glow: l(glow, other.glow),
            coreBrightness: l(coreBrightness, other.coreBrightness),
            rimIntensity: l(rimIntensity, other.rimIntensity),
            breathingAmplitude: l(breathingAmplitude, other.breathingAmplitude),
            rotationSpeed: l(rotationSpeed, other.rotationSpeed),
            waveAmplitude: l(waveAmplitude, other.waveAmplitude),
            inwardPull: l(inwardPull, other.inwardPull),
            deformation: l(deformation, other.deformation),
            particleVisibility: l(particleVisibility, other.particleVisibility),
            shellExpansion: l(shellExpansion, other.shellExpansion),
            focusBandIntensity: l(focusBandIntensity, other.focusBandIntensity),
            condensePulse: l(condensePulse, other.condensePulse),
            progressGlow: l(progressGlow, other.progressGlow),
            micReactivity: l(micReactivity, other.micReactivity),
            outputReactivity: l(outputReactivity, other.outputReactivity),
            dimming: l(dimming, other.dimming)
        )
    }

    // MARK: State mapping

    /// Maps a session state onto its resting visual configuration.
    ///
    /// With `reducedMotion`, all oscillating/travelling motion is removed and
    /// states communicate through brightness and color crossfades only.
    public static func configuration(
        for state: VoiceOrbState,
        reducedMotion: Bool = false
    ) -> VoiceOrbVisualConfiguration {
        let base: VoiceOrbVisualConfiguration
        switch state.kind {
        case .idle:
            base = VoiceOrbVisualConfiguration(
                energy: 0.30, glow: 0.22, coreBrightness: 0.55, rimIntensity: 0.35,
                breathingAmplitude: 0.015, rotationSpeed: 0.6, waveAmplitude: 0,
                inwardPull: 0, deformation: 0.10, particleVisibility: 0.35,
                shellExpansion: 0, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 0, outputReactivity: 0, dimming: 0
            )
        case .preparing:
            base = VoiceOrbVisualConfiguration(
                energy: 0.42, glow: 0.30, coreBrightness: 0.50, rimIntensity: 0.45,
                breathingAmplitude: 0.010, rotationSpeed: 0.9, waveAmplitude: 0,
                inwardPull: 0, deformation: 0.10, particleVisibility: 0.40,
                shellExpansion: 0.01, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 1, micReactivity: 0, outputReactivity: 0, dimming: 0
            )
        case .listening:
            base = VoiceOrbVisualConfiguration(
                energy: 0.68, glow: 0.58, coreBrightness: 0.78, rimIntensity: 0.72,
                breathingAmplitude: 0.012, rotationSpeed: 1.15, waveAmplitude: 0,
                inwardPull: 1, deformation: 0.42, particleVisibility: 0.78,
                shellExpansion: 0.045, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 1, outputReactivity: 0, dimming: 0
            )
        case .speechDetected:
            base = VoiceOrbVisualConfiguration(
                energy: 0.92, glow: 0.70, coreBrightness: 0.88, rimIntensity: 0.95,
                breathingAmplitude: 0.008, rotationSpeed: 1.45, waveAmplitude: 0,
                inwardPull: 1, deformation: 0.68, particleVisibility: 0.85,
                shellExpansion: 0.055, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 1, outputReactivity: 0, dimming: 0
            )
        case .transcribing:
            base = VoiceOrbVisualConfiguration(
                energy: 0.60, glow: 0.42, coreBrightness: 0.65, rimIntensity: 0.55,
                breathingAmplitude: 0.006, rotationSpeed: 1.6, waveAmplitude: 0,
                inwardPull: 0.25, deformation: 0.22, particleVisibility: 0.45,
                shellExpansion: 0.02, focusBandIntensity: 1, condensePulse: 0,
                progressGlow: 0, micReactivity: 0.15, outputReactivity: 0, dimming: 0
            )
        case .thinking:
            base = VoiceOrbVisualConfiguration(
                energy: 0.80, glow: 0.60, coreBrightness: 0.82, rimIntensity: 0.68,
                breathingAmplitude: 0.010, rotationSpeed: 1.55, waveAmplitude: 0,
                inwardPull: 0, deformation: 0.40, particleVisibility: 0.78,
                shellExpansion: 0.02, focusBandIntensity: 0, condensePulse: 1,
                progressGlow: 0, micReactivity: 0, outputReactivity: 0, dimming: 0
            )
        case .speaking:
            base = VoiceOrbVisualConfiguration(
                energy: 0.88, glow: 0.72, coreBrightness: 0.92, rimIntensity: 0.80,
                breathingAmplitude: 0.010, rotationSpeed: 1.25, waveAmplitude: 1,
                inwardPull: 0, deformation: 0.38, particleVisibility: 0.72,
                shellExpansion: 0.04, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 0, outputReactivity: 1, dimming: 0
            )
        case .interrupted:
            // Contracted energy, no waves. The coordinator hard-cuts waves on
            // entry; this resting state keeps them off while settling.
            base = VoiceOrbVisualConfiguration(
                energy: 0.35, glow: 0.30, coreBrightness: 0.55, rimIntensity: 0.45,
                breathingAmplitude: 0.010, rotationSpeed: 0.8, waveAmplitude: 0,
                inwardPull: 0, deformation: 0.12, particleVisibility: 0.40,
                shellExpansion: -0.01, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 0, outputReactivity: 0, dimming: 0.05
            )
        case .error:
            base = VoiceOrbVisualConfiguration(
                energy: 0.30, glow: 0.28, coreBrightness: 0.45, rimIntensity: 0.40,
                breathingAmplitude: 0.006, rotationSpeed: 0.5, waveAmplitude: 0,
                inwardPull: 0, deformation: 0.08, particleVisibility: 0.25,
                shellExpansion: 0, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 0, outputReactivity: 0, dimming: 0.15
            )
        case .disabled:
            base = VoiceOrbVisualConfiguration(
                energy: 0.12, glow: 0.08, coreBrightness: 0.25, rimIntensity: 0.20,
                breathingAmplitude: 0.004, rotationSpeed: 0.3, waveAmplitude: 0,
                inwardPull: 0, deformation: 0.04, particleVisibility: 0,
                shellExpansion: 0, focusBandIntensity: 0, condensePulse: 0,
                progressGlow: 0, micReactivity: 0, outputReactivity: 0, dimming: 0.35
            )
        }

        guard reducedMotion else { return base }
        return VoiceOrbVisualConfiguration(
            energy: base.energy,
            glow: base.glow,
            coreBrightness: base.coreBrightness,
            rimIntensity: base.rimIntensity,
            breathingAmplitude: 0,
            rotationSpeed: 0,
            waveAmplitude: 0,
            inwardPull: base.inwardPull * 0.25,
            deformation: 0,
            particleVisibility: 0,
            shellExpansion: 0,
            focusBandIntensity: 0,
            condensePulse: 0,
            progressGlow: base.progressGlow,
            micReactivity: base.micReactivity * 0.4,
            outputReactivity: base.outputReactivity * 0.4,
            dimming: base.dimming
        )
    }
}

// MARK: - Transition timing

/// Per-transition animation durations, kept inside the ranges from the spec.
/// Transitions are always interruptible: a new state captures the currently
/// displayed (mid-blend) configuration as its starting point.
public enum VoiceOrbTransitionTiming {
    public static func duration(from: VoiceOrbStateKind, to: VoiceOrbStateKind) -> Double {
        if from == to { return 0.15 }
        switch (from, to) {
        case (_, .interrupted):
            // Interruption must feel immediate.
            return 0.12
        case (.interrupted, _):
            // Short visual settle back into listening/idle.
            return 0.25
        case (_, .error):
            return 0.30
        case (.error, _):
            return 0.35
        case (_, .disabled), (.disabled, _):
            return 0.40
        case (.idle, .listening), (.preparing, .listening):
            return 0.20 // 150–250 ms
        case (.listening, .speechDetected):
            return 0.12 // 80–150 ms
        case (.speechDetected, .transcribing):
            return 0.24 // 180–300 ms
        case (.transcribing, .thinking):
            return 0.28 // 200–350 ms
        case (.thinking, .speaking):
            return 0.20 // 150–250 ms
        case (.listening, .idle), (.speaking, .idle):
            return 0.30
        default:
            return 0.25
        }
    }
}
