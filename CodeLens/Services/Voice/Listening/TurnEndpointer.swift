import Foundation

// MARK: - TurnEndpointer
//
// The turn-taking brain. Given a per-tick speech probability (from any
// VoiceActivityDetector) plus a per-tick "does the transcript sound finished?"
// confidence (from EndOfTurnEstimator), it decides WHEN a user turn starts and
// ends, and detects barge-in during TTS playback. This is the piece every
// serious voice assistant has and the old loop only half-had:
//
//   • Speech-start confirmation — a level must STAY up for `speechStart`
//     before we count it as the user talking. Debounces a cough / door slam.
//
//   • Adaptive end-of-turn — the silence we wait before handing the turn to
//     the LLM is interpolated between `minEndSilence` (utterance sounds
//     complete) and `maxEndSilence` (trailing "and…/the…/um…" → they're
//     mid-thought). This is the no-model turn-detector: snappy when you're
//     done, patient when you're not.
//
//   • Heard-speech gate — a turn only ends if we actually heard speech this
//     turn, so ambient silence never fabricates an empty turn.
//
//   • Barge-in — during playback, a stricter, armed probability test lets the
//     user cut the assistant off by speaking. (Reliability still depends on
//     echo cancellation / a neural VAD; energy bleed from the speaker is the
//     hard part and is why the bar is higher here.)
//
// Pure timing logic, no audio or actor dependencies — the caller drives it
// once per tick and acts on the returned Event.

final class TurnEndpointer {

    struct Config {
        /// How long speech must persist to count as turn onset.
        var speechStart: TimeInterval = 0.24
        /// End-of-turn silence when the utterance sounds COMPLETE.
        var minEndSilence: TimeInterval = 0.55
        /// End-of-turn silence when it sounds INCOMPLETE (mid-thought).
        var maxEndSilence: TimeInterval = 1.6
        /// Probability ≥ this counts as "speech present" while listening.
        var listenSpeechProb: Float = 0.5
        /// Grace after playback starts before barge-in arms (lets AEC settle).
        var bargeInArm: TimeInterval = 0.35
        /// How long user speech must persist during TTS to be a barge-in.
        var bargeInSpeech: TimeInterval = 0.22
        /// Stricter probability bar during playback (speaker bleeds into mic).
        var bargeInProb: Float = 0.85
    }

    enum Event: Equatable {
        case none
        case turnStarted     // confirmed user speech onset this turn
        case turnEnded       // end-of-turn → hand transcript to the LLM
        case bargeIn         // user spoke over the assistant → interrupt
    }

    private let config: Config

    // Listening state.
    private var aboveSince: Date?
    private var belowSince: Date?
    private var heardSpeech = false
    private var startEmitted = false

    // Speaking (barge-in) state.
    private var speakingStamp: Date?
    private var bargeAboveSince: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Resets

    /// Call when (re)entering the listening phase.
    func resetListening() {
        aboveSince = nil
        belowSince = nil
        heardSpeech = false
        startEmitted = false
    }

    /// Call when (re)entering the speaking phase.
    func resetSpeaking() {
        speakingStamp = nil
        bargeAboveSince = nil
    }

    // MARK: - Listening tick

    /// - probability: p(speech) for this tick.
    /// - completion: 0…1 from EndOfTurnEstimator (1 = sounds finished).
    func observeListening(probability p: Float, completion: Double, now: Date) -> Event {
        let speech = p >= config.listenSpeechProb

        if speech {
            belowSince = nil
            if aboveSince == nil { aboveSince = now }
            if let a = aboveSince, now.timeIntervalSince(a) >= config.speechStart {
                heardSpeech = true
                if !startEmitted {
                    startEmitted = true
                    return .turnStarted
                }
            }
            return .none
        }

        // Silence.
        aboveSince = nil
        guard heardSpeech else { return .none }  // never heard speech → no turn
        if belowSince == nil { belowSince = now }

        // Adaptive end-of-turn: longer wait the less complete it sounds.
        let c = max(0, min(1, completion))
        let need = config.maxEndSilence - (config.maxEndSilence - config.minEndSilence) * c
        if let b = belowSince, now.timeIntervalSince(b) >= need {
            return .turnEnded
        }
        return .none
    }

    // MARK: - Speaking tick (barge-in)

    func observeSpeaking(probability p: Float, now: Date) -> Event {
        if speakingStamp == nil { speakingStamp = now; bargeAboveSince = nil }
        guard let speakingStamp else { return .none }
        let armed = now.timeIntervalSince(speakingStamp) >= config.bargeInArm

        if armed && p >= config.bargeInProb {
            if bargeAboveSince == nil { bargeAboveSince = now }
            if let s = bargeAboveSince, now.timeIntervalSince(s) >= config.bargeInSpeech {
                return .bargeIn
            }
        } else {
            bargeAboveSince = nil
        }
        return .none
    }
}
