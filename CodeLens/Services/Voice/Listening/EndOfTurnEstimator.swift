import Foundation

// MARK: - EndOfTurnEstimator
//
// Semantic end-of-turn ("did the user actually finish talking?") without a
// model. This is the no-ML half of the industry-standard turn-detector: a
// pure-text heuristic over the recogniser's live partial transcript that
// tells the endpointer HOW LONG to wait for silence before handing the turn
// to the LLM.
//
// The problem it solves: a fixed silence cutoff either cuts people off when
// they pause mid-thought ("send me the file… [pause] …from yesterday") or
// feels laggy when they're clearly done. Real assistants vary the wait based
// on whether the utterance sounds complete. LiveKit/Pipecat ship a small
// transformer for this; we approximate the high-value 80% with trailing-token
// linguistics, which needs no model and ships today. When a neural
// turn-detector model is added later, it implements the same `confidence(for:)`
// contract and this becomes the fallback.
//
// Contract: `confidence(for:)` returns 0…1 where 1 == "almost certainly a
// complete utterance, end the turn on the SHORT silence window" and 0 ==
// "they're mid-sentence, wait the LONG window". The endpointer interpolates
// its end-of-turn silence between min/max using this value.

enum EndOfTurnEstimator {

    /// Tokens that, when they END an utterance, strongly suggest more speech
    /// is coming — conjunctions, articles, prepositions, and disfluencies.
    /// English-only by design: for other languages we return a neutral
    /// confidence so we neither hang nor clip (silence timing alone governs).
    private static let trailingIncompleteTokens: Set<String> = [
        // conjunctions / connectives
        "and", "but", "or", "so", "because", "if", "when", "while", "although",
        "though", "since", "unless", "until", "whereas", "plus", "also",
        // articles / determiners
        "the", "a", "an", "this", "that", "these", "those", "my", "your",
        "his", "her", "its", "our", "their",
        // prepositions
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "about",
        "into", "onto", "over", "under", "between", "through",
        // disfluencies / hedges
        "um", "uh", "er", "hmm", "like", "well", "okay", "ok", "so",
        // verbs that almost always take an object/complement
        "is", "are", "was", "were", "be", "been", "being", "i'm", "it's",
        "let's", "gonna", "wanna", "going",
        // common dangling words
        "i", "you", "we", "they", "he", "she", "it", "what", "which", "who",
        "very", "really", "just", "not"
    ]

    /// Sentence-final punctuation — a strong "done" signal when the recogniser
    /// has inserted it (iOS punctuation insertion is on for dictation).
    private static let terminalPunctuation: Set<Character> = [".", "!", "?"]

    /// Whether the transcript is plausibly English. We only apply the
    /// trailing-token grammar to English; everything else falls back to a
    /// neutral 0.5 so the silence timer alone decides (mid-confidence →
    /// roughly the midpoint wait).
    private static func isLikelyEnglish(_ text: String) -> Bool {
        // Cheap check: the transcript is mostly ASCII letters. Turkish,
        // Spanish, etc. carry diacritics / non-ASCII letters frequently
        // enough that this reliably routes them to the neutral branch.
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let ascii = letters.filter { $0.isASCII }
        return Double(ascii.count) / Double(letters.count) > 0.9
    }

    /// 0 = mid-sentence (wait long), 1 = complete (end fast).
    static func confidence(for transcript: String) -> Double {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0.5 }   // nothing yet → neutral

        // Terminal punctuation is the strongest complete signal and is
        // language-agnostic.
        if let last = trimmed.last, terminalPunctuation.contains(last) {
            return 1.0
        }

        guard isLikelyEnglish(trimmed) else { return 0.5 }

        let words = trimmed
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map(String.init)
        guard let lastWord = words.last else { return 0.5 }

        // A bare-start single word ("hey", "okay") is ambiguous — they may
        // be winding up. Don't rush it.
        if words.count < 2 { return 0.35 }

        // Trailing connective / article / disfluency → almost certainly more
        // coming. Wait the long window.
        let cleanLast = lastWord.trimmingCharacters(in: CharacterSet(charactersIn: ",;:-"))
        if trailingIncompleteTokens.contains(cleanLast) {
            return 0.1
        }

        // Trailing comma → mid-list / mid-clause, lean incomplete.
        if lastWord.hasSuffix(",") {
            return 0.25
        }

        // Otherwise it ends on a content word with no incomplete marker —
        // most likely a finished clause. Lean complete but not certain (no
        // terminal punctuation), so the endpointer still gives a little
        // grace over the pure-punctuation case.
        return 0.85
    }

    /// Convenience boolean for callers that just want a yes/no.
    static func looksComplete(_ transcript: String) -> Bool {
        confidence(for: transcript) >= 0.6
    }
}
