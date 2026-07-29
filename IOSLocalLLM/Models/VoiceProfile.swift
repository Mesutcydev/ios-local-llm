import Foundation

// MARK: - VoiceProfile
//
// Per-model knobs that drive the voice pipeline. Keyed by the same
// `AssistantModel.id` that `CodingAssistantService.activeModel` uses
// (presets and `downloaded:` / `imported:` / `custom:`-prefixed IDs).
// `VoiceProfileRegistry.profile(for:)` resolves a profile via
// exact-match → prefix-stripped substring match → `_fallback`, with
// user overrides layered on top of the base.

struct VoiceProfile: Equatable {

    /// The model id this profile represents — typically the preset
    /// key (`qwen3-4b`, `qwen2.5-coder-1.5b`, …) or the literal
    /// `_fallback` for the generic profile, but for resolved
    /// downloaded/imported variants it carries the original full
    /// id (e.g. `downloaded:Qwen/Qwen3-4B-Instruct-MLX-4bit`) so the
    /// caller knows where to find user overrides.
    let modelId: String

    /// When false, `ReasoningStripper` is bypassed entirely on the
    /// TTS path — skips the per-token feed cost for models that
    /// never emit chain-of-thought blocks. When true, the pattern
    /// below defines the open/close tags to strip.
    let usesReasoningTokens: Bool

    /// Override the default `<think>` / `</think>` tags if the model
    /// uses a different delimiter (`<reasoning>`, `[THINKING]`, …).
    /// `nil` falls back to ReasoningStripper's defaults.
    let reasoningTokenPattern: ReasoningPattern?

    /// Hints fed to `LanguageDetector` when classifying each chunk.
    /// Two-letter language codes (`en`, `tr`, `de`, …) — the
    /// detector folds these into both `languageConstraints` and a
    /// uniform prior. Empty array disables hinting.
    let dominantLanguages: [String]

    /// Which boundary detector to use for streaming TTS chunking.
    /// `.sentence` is the historical default (Assistant); `.clause`
    /// produces snappier audio for descriptive Lens narration.
    let chunkingStrategy: SemanticChunker.Strategy

    /// Multiplier applied to AVSpeech's base rate. Profile defaults
    /// only kick in when the user hasn't tuned `AppSettings.voiceSpeed`
    /// themselves — once they do, their value wins.
    let defaultTTSRate: Double
    let defaultTTSPitch: Double

    /// Force a specific engine when the user hasn't set a preference.
    /// `nil` means "use `AppSettings.voiceEngine`". The per-chunk
    /// language router still overrides this when a language mismatch
    /// would otherwise produce the wrong-locale voice.
    let preferredEngine: VoiceEngineKind?
}

// MARK: - ReasoningPattern
//
// A tuple was the original spec but Swift can't synthesise Equatable
// for tuples cleanly across module boundaries; a small nested struct
// is the smallest change that keeps the registry value-type-friendly.

struct ReasoningPattern: Equatable {
    let open: String
    let close: String

    static let qwenThink = ReasoningPattern(open: "<think>", close: "</think>")
    static let bracketThinking = ReasoningPattern(open: "[THINKING]", close: "[/THINKING]")
}
