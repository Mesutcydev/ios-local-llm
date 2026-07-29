import Foundation
import NaturalLanguage

// MARK: - LanguageDetector
//
// Thin wrapper around `NLLanguageRecognizer` for tagging speech-ready
// chunks before they hit the TTS engine. Each detected chunk gets a
// BCP-47 tag (`en-US`, `tr-TR`, `de-DE`, …) so the router can pick a
// voice that matches the language instead of speaking Turkish words
// through an American voice (or vice-versa).
//
// Hints. Apple's recogniser is biased on long inputs but flaps on
// short ones — `"OK."` could decode to almost any Latin-script
// language. The `hints` parameter tells `NLLanguageRecognizer` which
// languages are likely (via `languageHints`) and which to consider at
// all (via `languageConstraints`). For this surgical fix the caller
// hard-codes `["en", "tr"]`; when `VoiceProfileRegistry` lands in
// session 3, hints will come from the active model's profile
// (`dominantLanguages`).
//
// Output format. `detect(_:)` returns a BCP-47 string with a region
// guess folded in — `en` → `en-US`, `tr` → `tr-TR`, etc. AVSpeech
// voice lookups use the language prefix (`en`, `tr`) and the region
// only narrows ties between equivalent-quality voices, so we don't
// need to be precise about the region.
//
// Fallback. Empty or whitespace-only input returns nil — the caller
// should keep the current voice rather than pick something at random.
// Unknown / undetermined inputs also return nil for the same reason.

struct LanguageDetector {

    // MARK: - Singleton
    //
    // NLLanguageRecognizer is documented as not thread-safe, but a
    // single recognizer reused on the same queue is fine. Construct
    // once, reset between calls.

    static let shared = LanguageDetector()

    private let recognizer: NLLanguageRecognizer

    init() {
        self.recognizer = NLLanguageRecognizer()
    }

    // MARK: - Detect

    /// Detects the dominant language of `text` and returns a BCP-47
    /// tag, biased by the supplied hints. Returns `nil` when the
    /// detector has no confident answer (empty input, undetermined
    /// language, or hypothesis below the confidence floor).
    ///
    /// - Parameters:
    ///   - text: Chunk to classify. Sentence-sized inputs are ideal;
    ///     very short inputs (< 3 chars) often return nil.
    ///   - hints: Two-letter language codes the caller considers
    ///     plausible — typically the active model's
    ///     `dominantLanguages`. Drives both `languageHints`
    ///     (probabilities) and `languageConstraints` (allowlist).
    ///     Pass an empty array to disable both biases.
    ///   - minimumConfidence: Hypotheses below this probability are
    ///     ignored. Defaults to 0.5 — empirically the sweet spot
    ///     where short Turkish phrases ("Tamam." "Evet.") get
    ///     correctly tagged but ambiguous one-word English chunks
    ///     don't get over-confident.
    func detect(
        _ text: String,
        hints: [String] = ["en", "tr"],
        minimumConfidence: Double = 0.5
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        recognizer.reset()

        // languageConstraints is an allowlist when non-empty — anything
        // outside the set scores zero. languageHints is a soft prior.
        if !hints.isEmpty {
            recognizer.languageConstraints = hints.map { NLLanguage($0) }
            // Distribute the prior uniformly across hinted languages.
            // The recogniser combines this with its own evidence and
            // picks the maximum-likelihood result.
            let priorWeight = 1.0 / Double(hints.count)
            var priors: [NLLanguage: Double] = [:]
            for code in hints { priors[NLLanguage(code)] = priorWeight }
            recognizer.languageHints = priors
        } else {
            recognizer.languageConstraints = []
            recognizer.languageHints = [:]
        }

        recognizer.processString(trimmed)

        // Use the top hypothesis with its confidence — single
        // dominant-language read is more stable than walking the
        // top-N list for our short-chunk inputs.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hypotheses.first,
              confidence >= minimumConfidence
        else { return nil }
        // Skip `und` (undetermined) — the recogniser returns this
        // for inputs it can't classify even when constraints exist.
        guard language.rawValue != "und", !language.rawValue.isEmpty
        else { return nil }
        return bcp47(for: language)
    }

    // MARK: - BCP-47 mapping
    //
    // AVSpeech voice lookups match on the language prefix
    // (`AVSpeechSynthesisVoice(language: "tr-TR")` finds any Turkish
    // voice), so we fold a sensible default region in. This isn't
    // exhaustive — anything not in the table falls back to the
    // language code alone, which AVSpeech still resolves correctly.

    private static let regionByLanguage: [String: String] = [
        "en": "en-US",
        "tr": "tr-TR",
        "es": "es-ES",
        "fr": "fr-FR",
        "de": "de-DE",
        "it": "it-IT",
        "pt": "pt-BR",
        "ru": "ru-RU",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "zh": "zh-CN",
        "ar": "ar-SA",
        "nl": "nl-NL",
        "pl": "pl-PL",
        "sv": "sv-SE",
        "da": "da-DK",
        "no": "nb-NO",
        "fi": "fi-FI",
        "el": "el-GR",
        "he": "he-IL",
        "hi": "hi-IN",
        "th": "th-TH",
        "vi": "vi-VN",
        "id": "id-ID",
        "cs": "cs-CZ",
        "ro": "ro-RO",
        "hu": "hu-HU",
        "uk": "uk-UA",
    ]

    private func bcp47(for language: NLLanguage) -> String {
        let code = language.rawValue
        if let mapped = Self.regionByLanguage[code] { return mapped }
        return code
    }
}
