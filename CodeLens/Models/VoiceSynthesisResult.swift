import AVFoundation

// MARK: - VoiceSynthesisResult
// Returned by LocalVoiceEngine.synthesize().
// When pcmBuffer is non-nil, AudioPlaybackService plays it.
// Optional alignment carries engine-derived or precomputed timings.

struct VoiceSynthesisResult {
    /// PCM audio produced by the engine. Nil when the engine plays audio itself.
    let pcmBuffer: AVAudioPCMBuffer?

    /// Sample rate of the PCM data (or engine native rate).
    let sampleRate: Double

    /// Approximate duration in seconds.
    let duration: TimeInterval

    /// Which engine produced this result.
    let engineKind: VoiceEngineKind

    /// Voice ID used.
    let voiceID: String

    /// Optional karaoke alignment produced inside the engine adapter.
    let alignment: SpeechAlignmentResult?

    /// Raw synthesis metadata for downstream acoustic aligners.
    let synthesisMetadata: SynthesisMetadata?

    init(
        pcmBuffer: AVAudioPCMBuffer?,
        sampleRate: Double,
        duration: TimeInterval,
        engineKind: VoiceEngineKind,
        voiceID: String,
        alignment: SpeechAlignmentResult? = nil,
        synthesisMetadata: SynthesisMetadata? = nil
    ) {
        self.pcmBuffer = pcmBuffer
        self.sampleRate = sampleRate
        self.duration = duration
        self.engineKind = engineKind
        self.voiceID = voiceID
        self.alignment = alignment
        self.synthesisMetadata = synthesisMetadata
    }

    /// True when the engine returned raw PCM that must be played by AudioPlaybackService.
    var requiresExternalPlayback: Bool { pcmBuffer != nil }
}
