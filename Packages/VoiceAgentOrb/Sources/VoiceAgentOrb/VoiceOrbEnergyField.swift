import Foundation

/// A flowing internal energy field: a closed polar curve whose radius is a
/// sum of three fixed sinusoidal harmonics.
///
/// All harmonic *counts* around the circle are integers, so the shape wraps
/// seamlessly at θ = 2π. All speed multipliers are integers of a shared base
/// speed, so the motion loops seamlessly in time while looking non-repeating
/// (different amplitudes and phase offsets per harmonic).
///
/// The spec is a plain value type with fixed tuples — no arrays are created
/// when it is evaluated, so the render loop performs zero allocations.
public struct VoiceOrbEnergyField: Sendable, Equatable {
    /// Amplitudes of the three harmonics, as a fraction of the base radius.
    public var amplitudes: (Double, Double, Double)
    /// Integer lobe counts around the circle (seamless wrap).
    public var counts: (Double, Double, Double)
    /// Integer multiples of the base angular speed (seamless time loop).
    public var speeds: (Double, Double, Double)
    /// Fixed phase offsets per harmonic (radians).
    public var phases: (Double, Double, Double)
    /// Field radius as a fraction of the orb radius. `0.6...0.95`.
    public var baseRadius: Double
    /// Slow self-rotation of the whole field, radians per second.
    public var rotationSpeed: Double
    /// Base opacity of the field fill.
    public var alpha: Double

    public init(
        amplitudes: (Double, Double, Double),
        counts: (Double, Double, Double),
        speeds: (Double, Double, Double),
        phases: (Double, Double, Double),
        baseRadius: Double,
        rotationSpeed: Double,
        alpha: Double
    ) {
        self.amplitudes = amplitudes
        self.counts = counts
        self.speeds = speeds
        self.phases = phases
        self.baseRadius = baseRadius
        self.rotationSpeed = rotationSpeed
        self.alpha = alpha
    }

    public static func == (lhs: VoiceOrbEnergyField, rhs: VoiceOrbEnergyField) -> Bool {
        lhs.amplitudes.0 == rhs.amplitudes.0
            && lhs.amplitudes.1 == rhs.amplitudes.1
            && lhs.amplitudes.2 == rhs.amplitudes.2
            && lhs.counts.0 == rhs.counts.0
            && lhs.counts.1 == rhs.counts.1
            && lhs.counts.2 == rhs.counts.2
            && lhs.speeds.0 == rhs.speeds.0
            && lhs.speeds.1 == rhs.speeds.1
            && lhs.speeds.2 == rhs.speeds.2
            && lhs.phases.0 == rhs.phases.0
            && lhs.phases.1 == rhs.phases.1
            && lhs.phases.2 == rhs.phases.2
            && lhs.baseRadius == rhs.baseRadius
            && lhs.rotationSpeed == rhs.rotationSpeed
            && lhs.alpha == rhs.alpha
    }

    /// Base angular speed shared by all fields (rad/s). Fields loop every
    /// `2π / baseSpeed / 1` ≈ 26 s at multiplier 1.
    public static let baseSpeed: Double = 0.24

    /// Radial offset at angle `theta` and time `t`, as a fraction of the
    /// field's base radius. `level` modulates amplitude for audio reactivity,
    /// `inwardPull` biases the offset toward the center (listening), and
    /// `wave` adds an outward-travelling ripple (speaking).
    public func radiusOffset(
        theta: Double,
        t: Double,
        level: Double,
        deformation: Double,
        inwardPull: Double,
        wave: Double
    ) -> Double {
        let a = amplitudes
        let k = counts
        let w = speeds
        let p = phases
        let ts = t * Self.baseSpeed

        var value =
            a.0 * sin(k.0 * theta + w.0 * ts + p.0) +
            a.1 * sin(k.1 * theta - w.1 * ts + p.1) +
            a.2 * sin(k.2 * theta + w.2 * ts + p.2)

        // Audio-reactive amplitude, deformation widens the lobes.
        value *= (1 + level * 1.6) * (0.6 + deformation * 0.8)

        // Listening: energy pulled inward (negative = toward center).
        value -= inwardPull * (0.22 + level * 0.30)

        // Speaking: outward push following playback level.
        value += wave * (0.10 + level * 0.22)

        return value
    }
}

public extension VoiceOrbEnergyField {
    /// Three layered fields with distinct, non-integer-looking motion.
    /// Integer counts/speeds keep them seamlessly looping.
    static let primary = VoiceOrbEnergyField(
        amplitudes: (0.10, 0.06, 0.03),
        counts: (2, 3, 5),
        speeds: (1, 2, 3),
        phases: (0.0, 1.7, 3.9),
        baseRadius: 0.86,
        rotationSpeed: 0.10,
        alpha: 0.55
    )

    static let secondary = VoiceOrbEnergyField(
        amplitudes: (0.08, 0.05, 0.02),
        counts: (3, 4, 6),
        speeds: (2, 1, 3),
        phases: (2.1, 0.4, 5.1),
        baseRadius: 0.70,
        rotationSpeed: -0.14,
        alpha: 0.45
    )

    static let tertiary = VoiceOrbEnergyField(
        amplitudes: (0.06, 0.04, 0.02),
        counts: (4, 5, 7),
        speeds: (3, 2, 1),
        phases: (4.4, 2.6, 0.9),
        baseRadius: 0.52,
        rotationSpeed: 0.20,
        alpha: 0.40
    )

    /// Shared immutable table — created once, referenced per frame.
    static let all: [VoiceOrbEnergyField] = [primary, secondary, tertiary]
}

// MARK: - Particles

/// Deterministic fine particles contained inside the orb.
/// Positions derive from the loop index via fixed hashes — no per-frame
/// allocation, no random generation, perfectly repeatable motion.
public enum VoiceOrbParticles {
    /// Position of particle `i` (of `count`) inside the orb.
    /// Returns a point in unit-orb space centered at (0.5, 0.5), radius 0.5.
    public static func position(
        index i: Int,
        count: Int,
        t: Double,
        energy: Double
    ) -> CGPoint {
        // Deterministic pseudo-random seeds from the index.
        let fi = Double(i)
        let seedA = fract(sin(fi * 127.1 + 0.7) * 43758.5453)
        let seedB = fract(sin(fi * 269.5 + 1.3) * 28001.8384)
        let seedC = fract(sin(fi * 419.2 + 2.1) * 19341.7321)

        // Slow orbital drift; each particle has its own radius and speed.
        let direction: Double = seedC > 0.5 ? 1 : -1
        let angularSpeed = (0.05 + 0.12 * seedB) * direction
        let theta = seedA * 2 * .pi + t * angularSpeed
        let baseR = 0.10 + 0.34 * seedB
        // Gentle radial breathing per particle, energized by the state.
        let r = baseR * (1 + 0.10 * energy * sin(t * (0.4 + seedC * 0.5) + seedA * 6.28))

        return CGPoint(
            x: 0.5 + r * cos(theta),
            y: 0.5 + r * sin(theta)
        )
    }

    /// Radius (in unit-orb space, where the orb radius is 0.5) of particle `i`.
    public static func radius(index i: Int) -> Double {
        let seed = fract(sin(Double(i) * 311.7 + 4.2) * 53758.1123)
        return 0.004 + 0.010 * seed
    }

    private static func fract(_ x: Double) -> Double { x - x.rounded(.down) }
}
