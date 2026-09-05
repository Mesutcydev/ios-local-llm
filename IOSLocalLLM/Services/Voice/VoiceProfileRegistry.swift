import Foundation

// MARK: - VoiceProfileRegistry
//
// Resolves a `VoiceProfile` for any model id the assistant or lens
// pipeline might present. Resolution layers, in order:
//
//   1. **Built-in exact match.** A preset key (`qwen3-4b`,
//      `qwen2.5-coder-1.5b`, …) maps directly to its compiled-in
//      profile.
//
//   2. **Prefix-stripped substring match.** Real users load
//      HuggingFace models with IDs prefixed `downloaded:` /
//      `imported:` / `custom:` (see `AssistantModelCatalog.resolve-
//      NonPreset`). Strip the prefix and check whether the raw
//      repoID contains any built-in profile key as a case-
//      insensitive substring. Iterate longest-key-first so
//      `qwen3-4b` wins over `qwen3` when both could match.
//
//   3. **`_fallback`.** No match — return the generic profile and
//      log the unmatched id so future model additions are
//      discoverable in logs.
//
// User overrides (rate / pitch / engine / chunking strategy) are
// applied ON TOP of the base profile, keyed under
// `com.mesutcydev.ondevicecore.voice.profile.<modelId>.<field>` in UserDefaults.
// They beat built-in defaults but never replace the structural
// fields (`usesReasoningTokens`, `reasoningTokenPattern`,
// `dominantLanguages`) — those are model-architecture facts, not
// preferences.

enum VoiceProfileRegistry {

    // MARK: - Public API

    /// Returns the active profile for `modelId` — base profile from
    /// the resolution chain, with user overrides layered on top.
    static func profile(for modelId: String) -> VoiceProfile {
        let base = lookupBase(for: modelId)
        return applyOverrides(base, modelId: modelId)
    }

    /// The compiled-in built-in for `key` (no overrides, no
    /// substring resolution). Used by the customisation UI to show
    /// "factory defaults" alongside the user's current values.
    static func builtin(_ key: String) -> VoiceProfile? {
        Self.builtinProfiles[key]
    }

    // MARK: - Built-in catalog
    //
    // Keys match `AssistantModel.id` for presets. Vision-language
    // models (Lens) typically fall to `_fallback` because their
    // repoIDs are non-preset; the fallback profile is tuned for
    // English descriptive narration which works well for SmolVLM /
    // FastVLM / Qwen-VL captions.

    static let builtinProfiles: [String: VoiceProfile] = [

        // PrismML Bonsai models retain Qwen's <think> token contract. A
        // family-level key intentionally matches every Bonsai size/quant via
        // the registry's substring resolution path.
        "bonsai": VoiceProfile(
            modelId: "bonsai",
            usesReasoningTokens: true,
            reasoningTokenPattern: .qwenThink,
            dominantLanguages: ["en", "tr"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.5,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),

        // Qwen3 family — thinking mode emits `<think>…</think>` blocks
        // that MUST be stripped before TTS. Default rate is slightly
        // slower than 1.0 so reasoning-mode replies (which trend
        // longer) don't blur together.
        "qwen3-4b": VoiceProfile(
            modelId: "qwen3-4b",
            usesReasoningTokens: true,
            reasoningTokenPattern: .qwenThink,
            dominantLanguages: ["en", "tr"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.5,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),
        "qwen3-1.7b": VoiceProfile(
            modelId: "qwen3-1.7b",
            usesReasoningTokens: true,
            reasoningTokenPattern: .qwenThink,
            dominantLanguages: ["en", "tr"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.5,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),
        "qwen3-8b": VoiceProfile(
            modelId: "qwen3-8b",
            usesReasoningTokens: true,
            reasoningTokenPattern: .qwenThink,
            dominantLanguages: ["en", "tr"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.5,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),

        // Qwen2.5 family — no thinking tokens. Coder variant gets a
        // slightly slower rate so it spells out code-shaped phrases
        // more deliberately.
        "qwen2.5-coder-1.5b": VoiceProfile(
            modelId: "qwen2.5-coder-1.5b",
            usesReasoningTokens: false,
            reasoningTokenPattern: nil,
            dominantLanguages: ["en"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.5,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),
        "qwen2.5-7b": VoiceProfile(
            modelId: "qwen2.5-7b",
            usesReasoningTokens: false,
            reasoningTokenPattern: nil,
            dominantLanguages: ["en"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.52,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),

        // Llama / Phi / Gemma — no thinking tokens, English-focused.
        "llama-3.2-3b": VoiceProfile(
            modelId: "llama-3.2-3b",
            usesReasoningTokens: false,
            reasoningTokenPattern: nil,
            dominantLanguages: ["en"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.52,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),
        "phi-3.5-mini": VoiceProfile(
            modelId: "phi-3.5-mini",
            usesReasoningTokens: false,
            reasoningTokenPattern: nil,
            dominantLanguages: ["en"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.52,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),
        "gemma-2-2b": VoiceProfile(
            modelId: "gemma-2-2b",
            usesReasoningTokens: false,
            reasoningTokenPattern: nil,
            dominantLanguages: ["en"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.52,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),

        // Generic fallback — tuned for descriptive narration so a
        // Lens vision model (SmolVLM, FastVLM, etc.) that falls here
        // gets sensible clause-level chunking instead of long
        // run-on sentences.
        "_fallback": VoiceProfile(
            modelId: "_fallback",
            usesReasoningTokens: false,
            reasoningTokenPattern: nil,
            dominantLanguages: ["en"],
            chunkingStrategy: .sentence,
            defaultTTSRate: 0.5,
            defaultTTSPitch: 1.0,
            preferredEngine: nil
        ),
    ]

    /// Built-in keys sorted longest-first for the substring match.
    /// Computed once at first access — the dictionary is static so
    /// the sorted list never changes.
    private static let resolvableKeys: [String] = {
        builtinProfiles.keys
            .filter { $0 != "_fallback" }
            .sorted { $0.count > $1.count }
    }()

    // MARK: - Override storage
    //
    // Keys are namespaced per model so different models can carry
    // independent tweaks. Reads use raw `object(forKey:)` so we can
    // distinguish "user set the value" from "user has never touched
    // it." UserDefaults.standard.double(forKey:) returns 0.0 for
    // missing keys, which would silently zero out the rate.

    private static let overridePrefix = "com.mesutcydev.ondevicecore.voice.profile."

    /// Set or clear the user's rate override for `modelId`. `nil`
    /// removes the override (reverting to the profile default).
    static func setRateOverride(_ rate: Double?, for modelId: String) {
        let key = "\(overridePrefix)\(modelId).rate"
        if let rate {
            UserDefaults.standard.set(rate, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func setPitchOverride(_ pitch: Double?, for modelId: String) {
        let key = "\(overridePrefix)\(modelId).pitch"
        if let pitch {
            UserDefaults.standard.set(pitch, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func setEngineOverride(_ engine: VoiceEngineKind?, for modelId: String) {
        let key = "\(overridePrefix)\(modelId).engine"
        if let engine {
            UserDefaults.standard.set(engine.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Persists a chunking strategy as a stable string token. Only
    /// `.sentence` and `.clause` are exposable as user overrides —
    /// `.minWords(_)` is an internal-only mode used by Lens for
    /// captions with no punctuation and isn't surfaced in the UI.
    static func setChunkingStrategyOverride(_ strategy: SemanticChunker.Strategy?,
                                            for modelId: String) {
        let key = "\(overridePrefix)\(modelId).chunkingStrategy"
        if let strategy {
            UserDefaults.standard.set(encode(strategy), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Drop every user override for `modelId`. Useful for the
    /// settings-UI "reset to profile defaults" button.
    static func clearOverrides(for modelId: String) {
        let defaults = UserDefaults.standard
        for field in ["rate", "pitch", "engine", "chunkingStrategy"] {
            defaults.removeObject(forKey: "\(overridePrefix)\(modelId).\(field)")
        }
    }

    // MARK: - Resolution

    private static func lookupBase(for modelId: String) -> VoiceProfile {
        if let exact = builtinProfiles[modelId] { return exact }

        // Prefix-stripped substring match. `downloaded:`,
        // `imported:`, `custom:` come from `AssistantModelCatalog`'s
        // non-preset resolution path; stripping uncovers the raw
        // HuggingFace repoID to scan.
        let stripped = LocalModelRegistry.unwrapAssistantSelectionID(modelId)
        let lowered = stripped.lowercased()
        for key in resolvableKeys {
            if lowered.contains(key.lowercased()) {
                guard let base = builtinProfiles[key] else { continue }
                // Preserve the caller's modelId so override lookups
                // remain keyed by the actual id the user saw.
                return rebound(base, modelId: modelId)
            }
        }

        Diagnostics.shared.info("No profile match for \(modelId); using fallback", category: "voice")
        // _fallback exists by construction — force-unwrap is safe.
        return rebound(builtinProfiles["_fallback"]!, modelId: modelId)
    }
    /// Returns `base` with `modelId` replaced. All other fields are
    /// preserved by value. Used when a substring match resolves a
    /// `downloaded:` id back to a built-in profile but we want to
    /// keep override lookups keyed by the original full id.
    private static func rebound(_ base: VoiceProfile, modelId: String) -> VoiceProfile {
        VoiceProfile(
            modelId: modelId,
            usesReasoningTokens: base.usesReasoningTokens,
            reasoningTokenPattern: base.reasoningTokenPattern,
            dominantLanguages: base.dominantLanguages,
            chunkingStrategy: base.chunkingStrategy,
            defaultTTSRate: base.defaultTTSRate,
            defaultTTSPitch: base.defaultTTSPitch,
            preferredEngine: base.preferredEngine
        )
    }

    // MARK: - Override layering

    private static func applyOverrides(_ base: VoiceProfile, modelId: String) -> VoiceProfile {
        let defaults = UserDefaults.standard
        let prefix = "\(overridePrefix)\(modelId)"

        let rate    = (defaults.object(forKey: "\(prefix).rate")  as? Double) ?? base.defaultTTSRate
        let pitch   = (defaults.object(forKey: "\(prefix).pitch") as? Double) ?? base.defaultTTSPitch

        let engine: VoiceEngineKind?
        if let raw = defaults.string(forKey: "\(prefix).engine"),
           let kind = VoiceEngineKind(rawValue: raw) {
            engine = kind
        } else {
            engine = base.preferredEngine
        }

        let strategy: SemanticChunker.Strategy
        if let raw = defaults.string(forKey: "\(prefix).chunkingStrategy"),
           let decoded = decode(strategy: raw) {
            strategy = decoded
        } else {
            strategy = base.chunkingStrategy
        }

        return VoiceProfile(
            modelId: base.modelId,
            usesReasoningTokens: base.usesReasoningTokens,
            reasoningTokenPattern: base.reasoningTokenPattern,
            dominantLanguages: base.dominantLanguages,
            chunkingStrategy: strategy,
            defaultTTSRate: rate,
            defaultTTSPitch: pitch,
            preferredEngine: engine
        )
    }

    // MARK: - Strategy <-> String

    private static func encode(_ strategy: SemanticChunker.Strategy) -> String {
        switch strategy {
        case .sentence:        return "sentence"
        case .clause:          return "clause"
        case .minWords(let n): return "minWords:\(n)"
        }
    }

    private static func decode(strategy raw: String) -> SemanticChunker.Strategy? {
        switch raw {
        case "sentence": return .sentence
        case "clause":   return .clause
        default:
            if raw.hasPrefix("minWords:"),
               let n = Int(raw.dropFirst("minWords:".count)),
               n > 0 {
                return .minWords(n)
            }
            return nil
        }
    }
}
