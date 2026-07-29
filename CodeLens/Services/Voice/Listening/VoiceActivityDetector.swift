import Foundation
import CoreML

// MARK: - VoiceActivityDetector
//
// The speech/no-speech front-end of the turn-taking pipeline. Abstracted
// behind a protocol so the energy detector that ships today and a neural
// detector (Silero VAD) added later are interchangeable — the
// `TurnEndpointer` consumes a probability and never knows which produced it.
//
//   mic level / frames ─▶ VoiceActivityDetector ─▶ p(speech) ─▶ TurnEndpointer
//
// Probability contract: 0…1, where the endpointer treats ≥ 0.5 as "speech
// present this frame". An energy detector returns 0.5 exactly at its adaptive
// threshold; a neural detector returns the model's own posterior.

protocol VoiceActivityDetector: AnyObject, Sendable {
    /// Clears all adaptive/recurrent state. Called at the start of every
    /// listening turn so a previous turn's noise floor / LSTM state can't
    /// bleed forward.
    func reset()

    /// Speech probability for one tick.
    /// - level:  normalised RMS (0…1) from the mic meter — always available.
    /// - frames: raw 16 kHz mono samples for this tick, supplied only when a
    ///           frame-level detector is wired into the audio tap. The energy
    ///           detector ignores it; a neural detector requires it.
    func speechProbability(level: Float, frames: [Float]?) -> Float

    /// Async variant the voice loop calls each tick so a heavy (neural)
    /// detector can run its CoreML inference OFF the main actor instead of
    /// blocking it ~30×/s for the whole conversation. The loop awaits this
    /// before the next tick, so the detector's mutable state is never touched
    /// concurrently (single serialized consumer) — which is why conformers can
    /// safely be `@unchecked Sendable`.
    func speechProbabilityAsync(level: Float, frames: [Float]?) async -> Float
}

extension VoiceActivityDetector {
    /// Default: cheap detectors (EnergyVAD is a few multiplies) run inline on
    /// the caller — no point paying task-hop overhead. Heavy detectors override.
    func speechProbabilityAsync(level: Float, frames: [Float]?) async -> Float {
        speechProbability(level: level, frames: frames)
    }
}

// MARK: - EnergyVAD
//
// Adaptive energy-threshold detector. This is the proven math from the old
// inline VAD loop, lifted into the protocol so the turn-taking rewrite didn't
// also change the detection characteristics in one untestable step. It
// calibrates an ambient noise floor, tracks slow room-level drift, and fires
// when the smoothed level sits a multiple above the floor.
//
// It is genuinely fine for close-talk in a quiet room, and it's the safe
// default. It is NOT robust to background TV / music / babble — that's
// exactly the gap the neural detector closes (see the drop-in note below).

// `@unchecked Sendable`: all mutable state is touched only from the single
// serialized voice loop (one tick awaits the previous before the next), so
// there is no concurrent access despite the bare `var`s.
final class EnergyVAD: VoiceActivityDetector, @unchecked Sendable {

    // Tunables mirror the endpointer's old constants so behaviour is
    // unchanged until a neural detector replaces this.
    private let emaAlpha: Float = 0.35
    private let thresholdMultiplier: Float
    private let minLevel: Float
    private let calibrationTicks: Int

    private var smoothed: Float = 0
    private var noiseFloor: Float = 0.02
    private var calibrationSum: Float = 0
    private var calibrationCount: Int = 0
    private var calibrating = true

    /// Latest smoothed level — the orb UI reads this so the pulse tracks the
    /// same signal the detector decides on.
    private(set) var smoothedLevel: Float = 0

    /// - thresholdMultiplier: speech fires above `noiseFloor * this`.
    /// - minLevel: absolute floor so a silent room can't collapse the
    ///   multiplier onto breath noise.
    /// - calibrationTicks: ambient-sampling ticks before steady state
    ///   (e.g. 25 ticks * 20 ms = 500 ms).
    init(thresholdMultiplier: Float = 2.5,
         minLevel: Float = 0.05,
         calibrationTicks: Int = 25) {
        self.thresholdMultiplier = thresholdMultiplier
        self.minLevel = minLevel
        self.calibrationTicks = calibrationTicks
    }

    func reset() {
        smoothed = 0
        smoothedLevel = 0
        noiseFloor = 0.02
        calibrationSum = 0
        calibrationCount = 0
        calibrating = true
    }

    func speechProbability(level raw: Float, frames: [Float]?) -> Float {
        smoothed = emaAlpha * raw + (1 - emaAlpha) * smoothed
        smoothedLevel = smoothed

        // Calibration window — accumulate the ambient floor, report no speech.
        if calibrating {
            calibrationSum += smoothed
            calibrationCount += 1
            if calibrationCount >= calibrationTicks {
                if calibrationCount > 0 {
                    noiseFloor = max(calibrationSum / Float(calibrationCount), 0.01)
                }
                calibrating = false
            }
            return 0
        }

        let threshold = max(noiseFloor * thresholdMultiplier, minLevel)
        if smoothed < threshold {
            // Slow re-calibration while quiet so the floor tracks the room.
            noiseFloor = 0.85 * noiseFloor + 0.15 * smoothed
        }
        // Map level→probability so threshold == 0.5: the endpointer's ≥0.5
        // test then reproduces the old hard threshold exactly, while leaving
        // room for a soft probability from a neural detector.
        guard threshold > 0 else { return 0 }
        return min(1, smoothed / (2 * threshold))
    }
}

// MARK: - SileroVAD
//
// Neural voice-activity detection — the industry-standard front-end. Wraps the
// pre-compiled CoreML conversion of Silero VAD (FluidInference/silero-vad-coreml,
// MIT) bundled at Silero/silero_vad.mlmodelc. Robust to TV / music / babble in
// a way the energy detector can't be, because it's a trained speech classifier
// rather than a loudness threshold.
//
// Model contract (from the .mlmodelc metadata):
//   • input  `audio_chunk`     Float32 [1, 512]  — one 32 ms frame @ 16 kHz
//   • output `vad_probability` Float32 [1, 1]    — p(speech), no recurrent
//     state to thread between calls (this SE-trained variant is stateless
//     per chunk; the endpointer supplies the temporal smoothing).
//
// We receive 16 kHz mono `frames` per tick (resampled in the audio tap),
// buffer them into 512-sample windows, and run one prediction per full window.

// `@unchecked Sendable`: see EnergyVAD. The ring buffer, scratch MLMultiArray
// and MLModel are only ever touched from the serialized voice loop — one tick's
// `speechProbabilityAsync` is awaited to completion before the next tick (or a
// reset) runs, so the off-main inference never overlaps another access.
final class SileroVAD: VoiceActivityDetector, @unchecked Sendable {

    static let windowSize = 512   // Silero's fixed 16 kHz frame size

    private let model: MLModel
    private let scratch: MLMultiArray
    private var ring: [Float] = []
    private var lastProb: Float = 0

    /// Fails (returns nil) when the model isn't bundled or won't load, so the
    /// factory can fall back to EnergyVAD — Silero is an upgrade, never a hard
    /// dependency.
    init?() {
        guard let url = VoiceModelBundleValidator.sileroVADModelURL() else { return nil }
        let config = MLModelConfiguration()
        // CPU-only on purpose. This is a tiny model invoked ~30×/s on 512-sample
        // frames: the Neural Engine's per-call dispatch latency and warmup make
        // it slower here, it logs `ANECompiler: Cannot retrieve vector from
        // IRValue format int32` when it can't place one op, and the GPU is busy
        // with the LLM/VLM during a conversation. CPU is faster, quieter, and
        // contention-free for a frame-rate VAD.
        config.computeUnits = .cpuOnly
        guard let model = try? MLModel(contentsOf: url, configuration: config),
              let scratch = try? MLMultiArray(shape: [1, NSNumber(value: Self.windowSize)],
                                              dataType: .float32)
        else { return nil }
        self.model = model
        self.scratch = scratch
        ring.reserveCapacity(Self.windowSize * 4)
    }

    func reset() {
        ring.removeAll(keepingCapacity: true)
        lastProb = 0
    }

    func speechProbability(level: Float, frames: [Float]?) -> Float {
        if let frames, !frames.isEmpty { ring.append(contentsOf: frames) }

        // Run every full window accumulated since the last tick. Return the
        // max so a speech onset inside the tick isn't averaged away; hold the
        // previous value when we don't yet have a full window.
        var processedAny = false
        var best: Float = 0
        var consumed = 0
        while ring.count - consumed >= Self.windowSize {
            if let p = infer(offset: consumed) {
                best = max(best, p)
                processedAny = true
            }
            consumed += Self.windowSize
        }
        if consumed > 0 { ring.removeFirst(consumed) }
        if processedAny { lastProb = best }
        return lastProb
    }

    /// Runs the synchronous window-inference OFF the main actor. The voice loop
    /// is @MainActor; without this the CoreML `prediction` blocked it ~30×/s
    /// for the whole conversation, janking the orb/UI. The loop awaits the
    /// result before its next tick, so this never overlaps a reset() or another
    /// inference on the shared ring/scratch buffers.
    func speechProbabilityAsync(level: Float, frames: [Float]?) async -> Float {
        await Task.detached(priority: .userInitiated) { [self] in
            self.speechProbability(level: level, frames: frames)
        }.value
    }

    private func infer(offset: Int) -> Float? {
        let ptr = scratch.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSize)
        for i in 0 ..< Self.windowSize { ptr[i] = ring[offset + i] }
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: ["audio_chunk": MLFeatureValue(multiArray: scratch)]),
              let out = try? model.prediction(from: provider),
              let prob = out.featureValue(for: "vad_probability")?.multiArrayValue,
              prob.count > 0
        else { return nil }
        return prob[0].floatValue
    }
}

// MARK: - Factory
//
// Returns the best detector available: Silero when its model is bundled and
// loads, otherwise the energy detector. Both satisfy the same contract, so the
// endpointer and semantic end-of-turn behave identically either way — only the
// robustness of the speech/no-speech front-end changes.

enum VADFactory {
    static func makeDetector() -> VoiceActivityDetector {
        SileroVAD() ?? EnergyVAD()
    }
}
