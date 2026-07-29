import Testing
import Foundation
@testable import VoiceAgentOrb

// MARK: - Audio normalization & smoothing

@Suite("Audio level processing")
struct VoiceOrbLevelProcessorTests {

    @Test("Normalization endpoints and perceptual curve")
    func normalization() {
        // Endpoints.
        #expect(VoiceOrbLevelProcessor.normalize(0, noiseFloor: 0, gain: 6) == 0)
        #expect(VoiceOrbLevelProcessor.normalize(1, noiseFloor: 0, gain: 6) == 1)

        // Perceptual curve boosts quiet signals above linear.
        let mid = VoiceOrbLevelProcessor.normalize(0.5, noiseFloor: 0, gain: 6)
        #expect(mid > 0.5)
        #expect(mid < 1)

        // Monotonicity.
        var previous: Float = -1
        for i in 0...20 {
            let v = VoiceOrbLevelProcessor.normalize(Float(i) / 20, noiseFloor: 0.02, gain: 6)
            #expect(v >= previous)
            previous = v
        }

        // Noise floor removal.
        #expect(VoiceOrbLevelProcessor.normalize(0.02, noiseFloor: 0.02, gain: 6) == 0)

        // Non-finite input is clamped to silence.
        #expect(VoiceOrbLevelProcessor.normalize(.nan, noiseFloor: 0, gain: 6) == 0)
        #expect(VoiceOrbLevelProcessor.normalize(.infinity, noiseFloor: 0, gain: 6) == 0)
    }

    @Test("Attack is fast, release is slower")
    func attackRelease() {
        var attack = VoiceOrbLevelProcessor()
        var riseSteps: [Float] = []
        for _ in 0..<3 {
            riseSteps.append(attack.process(0.8, dt: 0.02))
        }
        // Fast attack: clearly responsive after ~60 ms.
        #expect(riseSteps.last ?? 0 > 0.35)

        var release = VoiceOrbLevelProcessor()
        for _ in 0..<30 { _ = release.process(0.9, dt: 0.02) }
        let peak = release.level
        var drop: Float = 0
        for _ in 0..<3 {
            drop = peak - release.process(0.2, dt: 0.02)
        }
        // Release over the same wall-clock window is much gentler than attack.
        let rise = riseSteps[0]
        #expect(drop < rise)

        // Release must still converge (not sticky).
        for _ in 0..<200 { _ = release.process(0, dt: 0.02) }
        #expect(release.level == 0)
    }

    @Test("Spike protection caps single-sample jumps")
    func spikeProtection() {
        var p = VoiceOrbLevelProcessor()
        // Absurd first sample: huge rms with a huge dt (first sample after pause).
        _ = p.process(1.0, dt: 2.0)
        #expect(p.level <= 0.5 + .ulpOfOne)

        // Normal attack steps are not constrained.
        var normal = VoiceOrbLevelProcessor()
        _ = normal.process(0.9, dt: 0.02)
        #expect(normal.level > 0.2)
    }

    @Test("Silence gate snaps room noise to zero")
    func silenceGate() {
        var p = VoiceOrbLevelProcessor()
        for _ in 0..<50 {
            _ = p.process(0.005, dt: 0.02) // below noise floor
        }
        #expect(p.level == 0)

        // After speech, low input decays into the gate and snaps to zero.
        for _ in 0..<30 { _ = p.process(0.8, dt: 0.02) }
        #expect(p.level > 0.5)
        for _ in 0..<200 { _ = p.process(0.005, dt: 0.02) }
        #expect(p.level == 0)
    }

    @Test("Input clamping")
    func clamping() {
        var p = VoiceOrbLevelProcessor()
        #expect(p.process(-5, dt: 0.02) == 0)
        let high = p.process(99, dt: 0.02)
        #expect(high <= 1)
        #expect(high.isFinite)
        #expect(p.process(.nan, dt: 0.02).isFinite)
        _ = p.process(0.5, dt: -1) // negative dt must not crash or regress
        #expect(p.level.isFinite)
    }
}

// MARK: - Audio model publishing

@MainActor
@Suite("Audio model")
final class VoiceOrbAudioModelTests {

    final class FakeClock: @unchecked Sendable {
        var t: TimeInterval = 1_000
    }

    @Test("Publishing is throttled and coalesced, then flushes")
    func throttledPublishing() async throws {
        let clock = FakeClock()
        let model = VoiceOrbAudioModel()
        model.now = { clock.t }

        model.submitMicrophoneRMS(0.5)
        let first = model.microphoneLevel
        #expect(first > 0)

        // Within the publish interval: coalesced, not published.
        clock.t += 0.004
        model.submitMicrophoneRMS(0.9)
        #expect(model.microphoneLevel == first)
        #expect(model.hasPendingFlush)

        // Past the interval: the scheduled flush delivers the latest value.
        clock.t += 0.02
        try await Task.sleep(for: .milliseconds(120))
        #expect(!model.hasPendingFlush)
        #expect(model.microphoneLevel > first)
    }

    @Test("Reset cancels pending work and zeroes levels")
    func reset() {
        let clock = FakeClock()
        let model = VoiceOrbAudioModel()
        model.now = { clock.t }

        // Two mic samples inside the publish interval → second is coalesced
        // into a pending flush (mic/output clocks are independent).
        model.submitMicrophoneRMS(0.8)
        clock.t += 0.004
        model.submitMicrophoneRMS(0.9)
        #expect(model.hasPendingFlush)

        model.reset()
        #expect(!model.hasPendingFlush)
        #expect(model.microphoneLevel == 0)
        #expect(model.outputLevel == 0)
        #expect(model.speechActivity == 0)
    }

    @Test("Rapid submission storm retains no tasks after reset")
    func stormNoRetainedTasks() {
        let clock = FakeClock()
        let model = VoiceOrbAudioModel()
        model.now = { clock.t }

        for i in 0..<2_000 {
            clock.t += 0.001
            model.submitMicrophoneRMS(Float((i % 10)) / 10)
            model.submitOutputRMS(Float((i % 5)) / 5)
            #expect(model.microphoneLevel.isFinite)
            #expect(model.outputLevel.isFinite)
        }
        model.reset()
        #expect(!model.hasPendingFlush)
        #expect(model.microphoneLevel == 0)
        #expect(model.outputLevel == 0)
    }
}

// MARK: - State → visual configuration mapping

@Suite("Visual configuration mapping")
struct VoiceOrbVisualConfigurationTests {

    @Test("Listening pulls inward and reacts to the microphone")
    func listening() {
        let config = VoiceOrbVisualConfiguration.configuration(for: .listening)
        #expect(config.inwardPull == 1)
        #expect(config.micReactivity == 1)
        #expect(config.waveAmplitude == 0)
        #expect(config.outputReactivity == 0)
        #expect(config.shellExpansion > 0) // alert expansion
    }

    @Test("Speaking pushes outward and is driven by playback, not mic")
    func speaking() {
        let config = VoiceOrbVisualConfiguration.configuration(for: .speaking)
        #expect(config.waveAmplitude == 1)
        #expect(config.outputReactivity == 1)
        #expect(config.inwardPull == 0)
        #expect(config.micReactivity == 0)
    }

    @Test("Listening and speaking are visually distinct")
    func distinctDirections() {
        let listening = VoiceOrbVisualConfiguration.configuration(for: .listening)
        let speaking = VoiceOrbVisualConfiguration.configuration(for: .speaking)
        #expect(listening.inwardPull != speaking.inwardPull)
        #expect(listening.waveAmplitude != speaking.waveAmplitude)
        #expect(listening.micReactivity != speaking.micReactivity)
    }

    @Test("Reduced motion strips oscillating motion everywhere")
    func reducedMotion() {
        for state in [
            VoiceOrbState.idle, .preparing(progress: 0.5), .listening,
            .speechDetected, .transcribing, .thinking, .speaking,
            .interrupted, .error(message: nil), .disabled,
        ] {
            let config = VoiceOrbVisualConfiguration.configuration(for: state, reducedMotion: true)
            #expect(config.breathingAmplitude == 0, "\(state.kind)")
            #expect(config.rotationSpeed == 0, "\(state.kind)")
            #expect(config.waveAmplitude == 0, "\(state.kind)")
            #expect(config.deformation == 0, "\(state.kind)")
            #expect(config.particleVisibility == 0, "\(state.kind)")
            #expect(config.condensePulse == 0, "\(state.kind)")
            // Brightness/energy channels stay for crossfade communication.
            #expect(config.energy > 0, "\(state.kind)")
        }
    }

    @Test("Transition durations stay inside spec ranges")
    func transitionTiming() {
        #expect(VoiceOrbTransitionTiming.duration(from: .idle, to: .listening) >= 0.15)
        #expect(VoiceOrbTransitionTiming.duration(from: .idle, to: .listening) <= 0.25)
        #expect(VoiceOrbTransitionTiming.duration(from: .listening, to: .speechDetected) <= 0.15)
        #expect(VoiceOrbTransitionTiming.duration(from: .transcribing, to: .thinking) <= 0.35)
        #expect(VoiceOrbTransitionTiming.duration(from: .speaking, to: .interrupted) <= 0.15)
        // Interruption is always fast, from any state.
        for kind in VoiceOrbStateKind.allCases {
            #expect(VoiceOrbTransitionTiming.duration(from: kind, to: .interrupted) <= 0.15)
        }
    }
}

// MARK: - Performance policy

@Suite("Performance policy")
struct VoiceOrbQualityControllerTests {

    @Test("Tier selection maps environment to quality")
    func tierSelection() {
        let controller = VoiceOrbQualityController()
        // Nominal/fair stay at balanced — never auto-select uncapped ProMotion work.
        #expect(controller.desiredQuality(for: .init()) == .balanced)
        #expect(controller.desiredQuality(for: .init(thermalState: .fair)) == .balanced)
        #expect(controller.desiredQuality(for: .init(thermalState: .serious)) == .reduced)
        #expect(controller.desiredQuality(for: .init(thermalState: .critical)) == .reduced)
        #expect(controller.desiredQuality(for: .init(lowPowerMode: true)) == .reduced)
        #expect(controller.desiredQuality(for: .init(reduceMotion: true)) == .reduced)
        #expect(controller.desiredQuality(for: .init(sceneActive: false)) == .reduced)
    }

    @Test("Thermal hysteresis prevents flapping")
    func hysteresis() {
        var controller = VoiceOrbQualityController()
        let nominal = VoiceOrbQualityController.Inputs(thermalState: .nominal)
        let serious = VoiceOrbQualityController.Inputs(thermalState: .serious)

        #expect(controller.quality == .balanced)

        // Serious heat: downgrades to reduced immediately.
        controller.evaluate(serious, now: 100)
        #expect(controller.quality == .reduced)

        // Oscillate serious/nominal: must not flap upgrades without a hold.
        for i in 0..<30 {
            let inputs = i % 2 == 0 ? nominal : serious
            controller.evaluate(inputs, now: 101 + Double(i))
            #expect(controller.quality == .reduced)
        }

        // Sustained nominal conditions eventually upgrade back to balanced.
        controller.evaluate(nominal, now: 200)
        #expect(controller.quality == .reduced)
        controller.evaluate(nominal, now: 200 + controller.upgradeHoldDuration + 1)
        #expect(controller.quality == .balanced)
    }

    @Test("Critical conditions downgrade immediately")
    func criticalDowngrade() {
        var controller = VoiceOrbQualityController()
        controller.evaluate(.init(thermalState: .critical), now: 50)
        #expect(controller.quality == .reduced)
        // Low power from any tier is immediate too.
        var second = VoiceOrbQualityController()
        second.evaluate(.init(lowPowerMode: true), now: 1)
        #expect(second.quality == .reduced)
    }
}

// MARK: - Animation coordinator

@MainActor
@Suite("Animation coordinator")
final class VoiceOrbAnimationCoordinatorTests {

    @Test("Transitions are interruptible mid-blend")
    func interruptibleTransitions() {
        let coordinator = VoiceOrbAnimationCoordinator()
        coordinator.setState(.listening, now: 0)
        // Half-way through the blend, redirect to thinking.
        coordinator.setState(.thinking, now: 0.1)
        let config = coordinator.configuration(at: 0.1)
        // The blend origin is the mid-flight configuration: energy is between
        // idle's 0.30 and listening's 0.55 — it never snaps.
        #expect(config.energy > 0.30)
        #expect(config.energy < 0.56)
    }

    @Test("Obsolete generation cannot reactivate an old state")
    func obsoleteTransitionCancellation() {
        let coordinator = VoiceOrbAnimationCoordinator()
        coordinator.setState(.listening, now: 0)
        let staleGeneration = coordinator.transitionGeneration
        coordinator.setState(.speaking, now: 0.05)
        #expect(coordinator.transitionGeneration != staleGeneration)

        coordinator.setState(.idle, now: 0.06, ifCurrentGeneration: staleGeneration)
        #expect(coordinator.state == .speaking)

        coordinator.setState(.idle, now: 0.06, ifCurrentGeneration: coordinator.transitionGeneration)
        #expect(coordinator.state == .idle)
    }

    @Test("Interruption hard-cuts waves and output reactivity immediately")
    func interruptionReset() {
        let coordinator = VoiceOrbAnimationCoordinator()
        coordinator.setState(.speaking, now: 0)

        // Fully settled into speaking: waves driven by output level.
        let speaking = coordinator.snapshot(at: 1.0, microphoneLevel: 0, outputLevel: 0.8, speechActivity: 0)
        #expect(speaking.outputLevel > 0.5)
        #expect(speaking.config.waveAmplitude > 0.9)

        // One frame after interruption: output gated, waves zero.
        coordinator.setState(.interrupted, now: 1.0)
        let interrupted = coordinator.snapshot(at: 1.008, microphoneLevel: 0, outputLevel: 0.8, speechActivity: 0)
        #expect(interrupted.outputLevel == 0)
        #expect(interrupted.config.waveAmplitude == 0)
        #expect(interrupted.interruptSettle > 0.9) // contraction pulse active

        // Settle decays.
        let settled = coordinator.snapshot(at: 2.0, microphoneLevel: 0, outputLevel: 0, speechActivity: 0)
        #expect(settled.interruptSettle == 0)
    }

    @Test("Speaking gate re-opens only on speaking")
    func outputGateRearm() {
        let coordinator = VoiceOrbAnimationCoordinator()
        coordinator.setState(.speaking, now: 0)
        coordinator.setState(.interrupted, now: 0.1)
        coordinator.setState(.listening, now: 0.2)
        // Output level must not leak into listening visuals.
        let listening = coordinator.snapshot(at: 1.0, microphoneLevel: 0, outputLevel: 0.9, speechActivity: 0)
        #expect(listening.outputLevel == 0)

        coordinator.setState(.speaking, now: 1.1)
        let speaking = coordinator.snapshot(at: 2.0, microphoneLevel: 0, outputLevel: 0.9, speechActivity: 0)
        #expect(speaking.outputLevel > 0.5)
    }

    @Test("Loading progress is clamped")
    func loadingProgressClamping() {
        let coordinator = VoiceOrbAnimationCoordinator()
        coordinator.setState(.preparing(progress: 1.7), now: 0)
        #expect(coordinator.loadingProgress == 1)

        coordinator.setState(.preparing(progress: -2), now: 0.1)
        #expect(coordinator.loadingProgress == 0)

        coordinator.setState(.preparing(progress: 0.4), now: 0.2)
        #expect(coordinator.loadingProgress == 0.4)

        // Non-finite progress keeps the previous value.
        coordinator.setState(.preparing(progress: .nan), now: 0.3)
        #expect(coordinator.loadingProgress == 0.4)
    }

    @Test("State equality prevents redundant transitions")
    func redundantState() {
        let coordinator = VoiceOrbAnimationCoordinator()
        coordinator.setState(.thinking, now: 0)
        let generation = coordinator.transitionGeneration
        coordinator.setState(.thinking, now: 0.1)
        #expect(coordinator.transitionGeneration == generation)
    }

    @Test("Rapid state storm: no crash, no stale tasks, coherent final state")
    func stressRapidStateChanges() {
        let coordinator = VoiceOrbAnimationCoordinator()
        let states: [VoiceOrbState] = [
            .idle, .preparing(progress: 0.2), .listening, .speechDetected,
            .transcribing, .thinking, .speaking, .interrupted,
            .error(message: "x"), .disabled,
        ]

        var now = 0.0
        var expectedChanges: UInt64 = 0
        for i in 0..<5_000 {
            now += 0.0005 + Double(i % 7) * 0.0003
            let next = states[i % states.count]
            if next != coordinator.state { expectedChanges &+= 1 }
            coordinator.setState(next, now: now)

            let snapshot = coordinator.snapshot(
                at: now, microphoneLevel: 0.7, outputLevel: 0.7, speechActivity: 0.5
            )
            #expect(snapshot.config.energy.isFinite)
            #expect(snapshot.breathingScale > 0.9 && snapshot.breathingScale < 1.1)
            #expect(snapshot.micLevel >= 0 && snapshot.micLevel <= 1)
            #expect(snapshot.outputLevel >= 0 && snapshot.outputLevel <= 1)
            #expect(snapshot.errorPulse >= 0 && snapshot.errorPulse <= 1)
            #expect(snapshot.interruptSettle >= 0 && snapshot.interruptSettle <= 1)
        }

        #expect(coordinator.transitionGeneration == expectedChanges)
        // Final configuration converges toward the last state's resting values.
        let last = states[(4_999) % states.count]
        let resting = VoiceOrbVisualConfiguration.configuration(for: last)
        let settled = coordinator.configuration(at: now + 10)
        #expect(abs(settled.energy - resting.energy) < 0.001)
        #expect(abs(settled.glow - resting.glow) < 0.001)
    }
}

// MARK: - Particles & fields

@Suite("Field and particle determinism")
struct VoiceOrbEnergyFieldTests {

    @Test("Field offsets wrap seamlessly around the circle")
    func seamlessWrap() {
        for field in VoiceOrbEnergyField.all {
            let a = field.radiusOffset(theta: 0, t: 3.3, level: 0.5, deformation: 0.3, inwardPull: 0, wave: 0)
            let b = field.radiusOffset(theta: 2 * Double.pi, t: 3.3, level: 0.5, deformation: 0.3, inwardPull: 0, wave: 0)
            #expect(abs(a - b) < 0.0001)
        }
    }

    @Test("Particle positions are deterministic and contained")
    func particles() {
        for i in 0..<36 {
            let p1 = VoiceOrbParticles.position(index: i, count: 36, t: 1.23, energy: 0.5)
            let p2 = VoiceOrbParticles.position(index: i, count: 36, t: 1.23, energy: 0.5)
            #expect(p1 == p2)
            // Contained inside the unit orb (radius 0.5 around the center).
            let dx = p1.x - 0.5
            let dy = p1.y - 0.5
            #expect(sqrt(dx * dx + dy * dy) < 0.5)
        }
    }
}
