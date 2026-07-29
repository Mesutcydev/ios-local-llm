import SwiftUI
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - Interactive demo

/// Interactive debug view that cycles through the full conversation flow:
///
/// idle → preparing → listening → speech detected → transcribing → thinking
/// → speaking → interrupted → listening → idle
///
/// Microphone and playback levels are simulated with speech-like envelopes
/// and pushed through the real ``VoiceOrbAudioModel`` smoothing/throttling
/// pipeline — the same path a production integration uses.
public struct VoiceOrbDemoView: View {

    @StateObject private var audioModel = VoiceOrbAudioModel()
    @State private var state: VoiceOrbState = .idle
    @State private var autoCycle = true
    @State private var startDate = Date()

    private struct CycleStep: Sendable {
        let state: VoiceOrbState
        let duration: Double
    }

    private static let cycle: [CycleStep] = [
        .init(state: .idle, duration: 2.2),
        .init(state: .preparing(progress: nil), duration: 2.8),
        .init(state: .listening, duration: 2.2),
        .init(state: .speechDetected, duration: 1.6),
        .init(state: .transcribing, duration: 2.0),
        .init(state: .thinking, duration: 2.6),
        .init(state: .speaking, duration: 3.2),
        .init(state: .interrupted, duration: 0.8),
        .init(state: .listening, duration: 1.6),
        .init(state: .idle, duration: 2.4),
    ]

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            TimelineView(.animation) { timeline in
                VoiceAgentOrb(
                    state: state,
                    microphoneLevel: audioModel.microphoneLevel,
                    outputLevel: audioModel.outputLevel,
                    speechActivity: audioModel.speechActivity,
                    size: 280
                )
                .onChange(of: timeline.date) { _, date in
                    guard autoCycle else { return }
                    advance(to: date)
                }
            }

            Toggle("Auto cycle", isOn: $autoCycle)
                .labelsHidden()

            if !autoCycle {
                manualControls
            }
        }
        .padding()
    }

    private var manualControls: some View {
        let columns = [GridItem(.adaptive(minimum: 96))]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(VoiceOrbStateKind.allCases, id: \.self) { kind in
                Button(kind.rawValue) {
                    state = Self.state(for: kind)
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
    }

    private static func state(for kind: VoiceOrbStateKind) -> VoiceOrbState {
        switch kind {
        case .idle: return .idle
        case .preparing: return .preparing(progress: 0.5)
        case .listening: return .listening
        case .speechDetected: return .speechDetected
        case .transcribing: return .transcribing
        case .thinking: return .thinking
        case .speaking: return .speaking
        case .interrupted: return .interrupted
        case .error: return .error(message: "Example error")
        case .disabled: return .disabled
        }
    }

    // MARK: Cycle + simulated audio

    private func advance(to date: Date) {
        let elapsed = date.timeIntervalSince(startDate)
        let (stepState, stepProgress) = Self.cyclePosition(at: elapsed)

        if case .preparing = stepState {
            state = .preparing(progress: stepProgress)
        } else if stepState != state {
            state = stepState
        }

        // Simulated, speech-like audio driven through the real model.
        let t = date.timeIntervalSinceReferenceDate
        switch state.kind {
        case .listening, .speechDetected:
            audioModel.submitMicrophoneRMS(Self.simulatedVoiceLevel(time: t, seed: 1.3))
            audioModel.submitOutputRMS(0.01)
        case .speaking:
            audioModel.submitOutputRMS(Self.simulatedVoiceLevel(time: t, seed: 4.1))
            audioModel.submitMicrophoneRMS(0.012)
        default:
            audioModel.submitMicrophoneRMS(0.012)
            audioModel.submitOutputRMS(0.010)
        }
    }

    private static func cyclePosition(at elapsed: Double) -> (VoiceOrbState, Double) {
        let total = cycle.reduce(0) { $0 + $1.duration }
        var t = elapsed.truncatingRemainder(dividingBy: total)
        for step in cycle {
            if t < step.duration {
                return (step.state, step.duration > 0 ? t / step.duration : 0)
            }
            t -= step.duration
        }
        return (.idle, 0)
    }

    /// Speech-like envelope: bursts with silence gaps and syllable structure.
    static func simulatedVoiceLevel(time: Double, seed: Double) -> Float {
        let gate = sin(time * 0.9 + seed) * sin(time * 0.53 + seed * 1.7)
        guard gate > -0.1 else { return 0.015 }
        let syllables = 0.5 + 0.5 * sin(time * 8.0 + seed * 3.0)
            * (0.55 + 0.45 * sin(time * 3.7 + seed))
        let level = 0.18 + 0.60 * syllables * min(gate + 0.35, 1)
        return Float(min(level, 1))
    }
}

// MARK: - Example pipeline integration

/// Reference integration between a local voice pipeline and the orb.
///
/// Wiring contract (this is the important part):
/// - `.speaking` begins from the engine's **playback-start** callback — never
///   from "generation finished".
/// - Speaking stops from the **playback-stop / playback-interrupt** callback.
/// - Listening visuals use captured microphone RMS.
/// - Speaking visuals use PCM output RMS from the player/tap.
/// - Nothing is derived from text length, token speed, or guessed durations.
@MainActor
public final class VoiceSessionOrbAdapter: ObservableObject {

    /// Current orb state; bind `VoiceAgentOrb(state:)` to this.
    @Published public private(set) var state: VoiceOrbState = .idle

    /// Shared audio model for both directions of audio.
    public let audioModel = VoiceOrbAudioModel()

    public init() {}

    // MARK: Model loading

    /// Call from your model loader's progress callback.
    public func modelLoadProgress(_ progress: Double) {
        state = .preparing(progress: progress)
    }

    public func modelDidBecomeReady() {
        state = .idle
    }

    // MARK: Microphone capture (input tap)

    #if canImport(AVFoundation)
    /// Call from the `AVAudioEngine` input tap. RMS is computed on the audio
    /// thread (real-time safe), the smoothing/publishing hop to MainActor.
    nonisolated func handleMicrophoneBuffer(_ buffer: AVAudioPCMBuffer) {
        let rms = VoiceOrbRMS.compute(buffer)
        Task { [audioModel] in
            await audioModel.submitMicrophoneRMS(rms)
        }
    }
    #endif

    /// Normalized RMS from any other capture source.
    public func handleMicrophoneRMS(_ rms: Float) {
        audioModel.submitMicrophoneRMS(rms)
    }

    // MARK: Voice activity detection

    public func vadDidDetectSpeechStart() {
        state = .speechDetected
    }

    public func vadDidDetectSpeechEnd() {
        state = .transcribing
    }

    public func listeningDidStart() {
        state = .listening
    }

    // MARK: Local STT / LLM

    public func transcriptionDidFinish() {
        state = .thinking
    }

    /// Intentionally does nothing visual: token generation speed must not
    /// drive the animation. The orb keeps "thinking" until playback starts.
    public func llmDidProduceToken() {}

    // MARK: Local TTS playback

    /// Call from the player's actual playback-start callback.
    public func playbackDidStart() {
        let signpost = VoiceOrbSignpost.begin("PlaybackStartToSpeaking")
        state = .speaking
        VoiceOrbSignpost.end("PlaybackStartToSpeaking", signpost)
    }

    /// Call from an output tap on the playback engine (PCM → RMS).
    public func handleOutputRMS(_ rms: Float) {
        audioModel.submitOutputRMS(rms)
    }

    /// Natural playback completion.
    public func playbackDidFinish() {
        state = .listening
    }

    /// Barge-in / interruption: stop speaking visuals immediately.
    public func playbackWasInterrupted() {
        let signpost = VoiceOrbSignpost.begin("InterruptToVisualStop")
        // Kill smoothed level tails so no stale energy keeps animating.
        audioModel.reset()
        state = .interrupted
        VoiceOrbSignpost.end("InterruptToVisualStop", signpost)
    }

    // MARK: Errors / lifecycle

    public func pipelineDidFail(message: String?) {
        state = .error(message: message)
    }

    public func pipelineDidBecomeUnavailable() {
        state = .disabled
    }

    public func sessionDidEnd() {
        audioModel.reset()
        state = .idle
    }
}

// MARK: - Previews

#Preview("All states") {
    let states: [VoiceOrbState] = [
        .idle, .preparing(progress: 0.6), .listening, .speechDetected,
        .transcribing, .thinking, .speaking, .interrupted,
        .error(message: "Mic unavailable"), .disabled,
    ]
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
        ForEach(Array(states.enumerated()), id: \.offset) { _, state in
            VoiceAgentOrb(state: state, size: 140)
        }
    }
    .padding()
}

#Preview("Light / dark") {
    HStack(spacing: 32) {
        VoiceAgentOrb(state: .thinking, size: 200)
            .preferredColorScheme(.light)
        VoiceAgentOrb(state: .thinking, size: 200)
            .preferredColorScheme(.dark)
    }
    .padding()
}

#Preview("Sizes") {
    HStack(spacing: 24) {
        VoiceAgentOrb(state: .listening, size: 120, showsStatusLabel: false)
        VoiceAgentOrb(state: .listening, size: 220, showsStatusLabel: false)
        VoiceAgentOrb(state: .listening, size: 340, showsStatusLabel: false)
    }
    .padding()
}

#Preview("Reduce Motion (forced reduced quality)") {
    // `accessibilityReduceMotion` is not writable via `.environment` on all
    // SDK builds — force the reduced tier the orb uses under Reduce Motion.
    VoiceAgentOrb(
        state: .speaking,
        outputLevel: 0.6,
        size: 240,
        qualityOverride: .reduced
    )
}

#Preview("Quality tiers") {
    HStack(spacing: 32) {
        VoiceAgentOrb(state: .thinking, size: 200,
                      showsStatusLabel: false, qualityOverride: .full)
        VoiceAgentOrb(state: .thinking, size: 200,
                      showsStatusLabel: false, qualityOverride: .reduced)
    }
    .padding()
}

#Preview("Simulated microphone") {
    VoiceOrbSimulatedAudioPreview(source: .microphone)
}

#Preview("Simulated TTS output") {
    VoiceOrbSimulatedAudioPreview(source: .playback)
}

#Preview("Rapid interruption") {
    VoiceOrbInterruptionPreview()
}

#Preview("Model loading progress") {
    VoiceOrbProgressPreview()
}

#Preview("Interactive cycle") {
    VoiceOrbDemoView()
}

// MARK: - Preview hosts

private enum SimulatedSource {
    case microphone, playback
}

/// Feeds a simulated speech envelope through the real audio model so the
/// preview exercises smoothing, gating and throttling exactly like production.
private struct VoiceOrbSimulatedAudioPreview: View {
    let source: SimulatedSource
    @StateObject private var audioModel = VoiceOrbAudioModel()

    var body: some View {
        TimelineView(.animation) { timeline in
            VoiceAgentOrb(
                state: source == .microphone ? .speechDetected : .speaking,
                microphoneLevel: audioModel.microphoneLevel,
                outputLevel: audioModel.outputLevel,
                speechActivity: audioModel.speechActivity,
                size: 240
            )
            .onChange(of: timeline.date) { _, date in
                let t = date.timeIntervalSinceReferenceDate
                let level = VoiceOrbDemoView.simulatedVoiceLevel(time: t, seed: 2.2)
                switch source {
                case .microphone:
                    audioModel.submitMicrophoneRMS(level)
                case .playback:
                    audioModel.submitOutputRMS(level)
                }
            }
        }
    }
}

/// speaking → interrupted → listening on a tight loop, with the output
/// level hard-cut at interruption exactly like a real barge-in.
private struct VoiceOrbInterruptionPreview: View {
    @StateObject private var audioModel = VoiceOrbAudioModel()
    @State private var state: VoiceOrbState = .speaking
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            VoiceAgentOrb(
                state: state,
                microphoneLevel: audioModel.microphoneLevel,
                outputLevel: audioModel.outputLevel,
                size: 240
            )
            .onChange(of: timeline.date) { _, date in
                let elapsed = date.timeIntervalSince(startDate)
                let t = date.timeIntervalSinceReferenceDate
                let phase = elapsed.truncatingRemainder(dividingBy: 3.4)
                let newState: VoiceOrbState
                if phase < 1.8 {
                    newState = .speaking
                    audioModel.submitOutputRMS(
                        VoiceOrbDemoView.simulatedVoiceLevel(time: t, seed: 3.3)
                    )
                } else if phase < 2.3 {
                    newState = .interrupted
                    if state != .interrupted { audioModel.reset() }
                } else {
                    newState = .listening
                    audioModel.submitMicrophoneRMS(
                        VoiceOrbDemoView.simulatedVoiceLevel(time: t, seed: 5.7)
                    )
                }
                if newState != state { state = newState }
            }
        }
    }
}

/// Looping model-load progress ramp (0 → 1) through the preparing state.
private struct VoiceOrbProgressPreview: View {
    @State private var startDate = Date()
    @State private var state: VoiceOrbState = .preparing(progress: 0)

    var body: some View {
        TimelineView(.animation) { timeline in
            VoiceAgentOrb(state: state, size: 240)
                .onChange(of: timeline.date) { _, date in
                    let elapsed = date.timeIntervalSince(startDate)
                    let progress = (elapsed / 4).truncatingRemainder(dividingBy: 1)
                    state = .preparing(progress: progress)
                }
        }
    }
}
