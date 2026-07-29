import Foundation

// MARK: - SemanticChunker
//
// Sentence/clause/minWords boundary detector for streaming TTS. Owns
// the running text buffer and an offset into it; each `append(_:)`
// returns one Chunk (or none) covering everything from the previous
// offset up to the last boundary found. `finish()` returns the tail
// when the stream ends.
//
// The `.sentence` strategy is bit-for-bit identical to the in-tree
// cutter that used to live as a private static on
// `VoiceConversationService` (`sentenceBoundaryIndex(in:after:)`). The
// same edge cases are preserved verbatim:
//
//   • Boundary fires on `. ! ?` + whitespace OR `\n\n`.
//   • Consecutive terminators (`...!?`) are coalesced into one
//     boundary so "Wait... what?!" doesn't produce two chunks.
//   • A `.`/`!`/`?` at the very end of the buffer with no following
//     whitespace is a "tail terminator" — we deliberately defer it
//     to the `finish()` flush so the final in-flight token doesn't
//     prematurely ship. The conversation-service `onComplete` path
//     is the single source of truth for end-of-reply audio.
//   • Minimum 12 chars from the previous offset — too-short slices
//     produce "Hi."-sized utterances that sound clipped on AVSpeech.
//
// Known limitations carried forward (intentional — improvements are
// for a future session, not this extraction):
//
//   • Decimals like `5.5 ` flush after the `.5 ` (the `5` before the
//     space is a digit, not a terminator-skip target, so the
//     `<period><whitespace>` rule fires).
//   • Honorifics like `Mr. Smith ` flush at `Mr. ` for the same
//     reason.
//   • No exclusion list. Add one in a future session.

final class SemanticChunker {

    // MARK: - Strategy

    enum Strategy: Hashable {
        /// `. ! ?` + whitespace OR `\n\n`. Default; matches the
        /// historical conversation-mode cutter exactly.
        case sentence

        /// `.sentence` PLUS `, ; :` + whitespace + word. Used by the
        /// Lens descriptive narration in session 3 for snappier
        /// chunking. NOT used by the conversation pipeline.
        case clause

        /// Flushes once at least N whitespace-delimited words have
        /// accumulated and the next character is whitespace. Useful
        /// for un-punctuated narration. Mid-word reads do not flush.
        case minWords(Int)
    }

    // MARK: - Output

    struct Chunk: Equatable {
        let text: String
        /// True when this chunk was produced by `finish()` rather
        /// than `append(_:)`. Callers that need to behave differently
        /// at the tail (e.g. "kick off playback if we haven't yet")
        /// read this flag.
        let isFinal: Bool
    }

    // MARK: - Config

    let strategy: Strategy
    let minChars: Int

    init(strategy: Strategy = .sentence, minChars: Int = 12) {
        self.strategy = strategy
        self.minChars = minChars
    }

    // MARK: - State

    /// Accumulated grapheme stream. Using `[Character]` is what the
    /// historical cutter used — keeps boundary indices grapheme-
    /// aligned, which `String.Index(offsetBy:)` then resolves to a
    /// `Character` offset (not a UTF-8 byte offset). Multi-byte
    /// languages (Turkish `şğ`, CJK, emoji) survive without splits.
    private var buffer: [Character] = []
    /// Offset (in grapheme units) up to which we've already emitted
    /// chunks. Search starts here on each call.
    private var emittedUpTo: Int = 0

    // MARK: - API

    /// Append new text to the buffer; return any complete chunks
    /// ready to play. In `.sentence` mode at most one chunk is
    /// returned per call (the slice up to the last boundary seen),
    /// matching the historical behavior. Other strategies behave
    /// identically — one chunk per call covering up to the latest
    /// qualifying boundary.
    @discardableResult
    func append(_ text: String) -> [Chunk] {
        guard !text.isEmpty else { return [] }
        buffer.append(contentsOf: text)
        guard let cut = nextBoundary(after: emittedUpTo) else { return [] }
        let slice = String(buffer[emittedUpTo ..< cut])
        emittedUpTo = cut
        return [Chunk(text: slice, isFinal: false)]
    }

    /// Flush any remaining buffered content. Called by the consumer
    /// at end-of-stream so the trailing fragment (that the cutter
    /// deliberately deferred) gets a chance to play.
    func finish() -> Chunk? {
        guard emittedUpTo < buffer.count else { return nil }
        let slice = String(buffer[emittedUpTo ..< buffer.count])
        emittedUpTo = buffer.count
        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Chunk(text: slice, isFinal: true)
    }

    /// Drop all buffered state. Call between conversation turns.
    func reset() {
        buffer.removeAll()
        emittedUpTo = 0
    }

    // MARK: - Boundary detection
    //
    // Returns the FIRST offset > `start` that satisfies the active
    // strategy's boundary AND respects the minChars minimum. The
    // historical cutter returned the LAST boundary in the buffer —
    // that wins when multiple boundaries arrive in a single token
    // batch. Preserved here verbatim.

    private func nextBoundary(after start: Int) -> Int? {
        switch strategy {
        case .sentence:
            return lastSentenceOrClauseBoundary(after: start, includeClause: false)
        case .clause:
            return lastSentenceOrClauseBoundary(after: start, includeClause: true)
        case .minWords(let n):
            return lastMinWordsBoundary(after: start, minWords: n)
        }
    }

    // MARK: - Sentence/clause boundary
    //
    // Ported verbatim from VoiceConversationService.sentenceBoundary-
    // Index (the historical implementation). The only addition is the
    // `includeClause` flag which extends the terminator set; clauses
    // additionally require the next character to be a word character
    // so a `, 5` numeric series doesn't trigger but `, then` does.

    private func lastSentenceOrClauseBoundary(after start: Int, includeClause: Bool) -> Int? {
        guard start < buffer.count else { return nil }

        var lastBoundary: Int? = nil
        var i = start
        while i < buffer.count {
            let c = buffer[i]
            if c == "." || c == "!" || c == "?" {
                let next = i + 1
                if next >= buffer.count {
                    // Tail terminator — defer to the finish() path.
                    // This is what keeps single-sentence in-flight
                    // tokens from streaming before the LLM completes.
                    break
                }
                if buffer[next].isWhitespace {
                    // Coalesce consecutive sentence terminators so
                    // `Wait... what?!` produces one boundary, not
                    // three.
                    var end = next
                    var scan = i
                    while scan < buffer.count - 1,
                          buffer[scan + 1] == "." || buffer[scan + 1] == "!" || buffer[scan + 1] == "?" {
                        scan += 1
                        end = scan + 1
                    }
                    if end < buffer.count, buffer[end].isWhitespace {
                        lastBoundary = end + 1
                        i = end + 1
                        continue
                    }
                }
            }
            if includeClause && (c == "," || c == ";" || c == ":") {
                let next = i + 1
                if next < buffer.count, buffer[next].isWhitespace {
                    // Clause break requires a word char to follow
                    // the whitespace — otherwise sequences like
                    // `:\n\n` or `,\n` don't fire twice (once as
                    // clause, once as paragraph).
                    let after = next + 1
                    if after < buffer.count, buffer[after].isLetter || buffer[after].isNumber {
                        lastBoundary = next + 1
                        i = next + 1
                        continue
                    }
                }
            }
            if c == "\n" && i + 1 < buffer.count && buffer[i + 1] == "\n" {
                lastBoundary = i + 2
                i += 2
                continue
            }
            i += 1
        }

        if let lb = lastBoundary, lb - start >= minChars {
            return lb
        }
        return nil
    }

    // MARK: - minWords boundary

    private func lastMinWordsBoundary(after start: Int, minWords: Int) -> Int? {
        guard minWords > 0, start < buffer.count else { return nil }

        // Walk forward counting whitespace-delimited word starts.
        // The boundary is at the FIRST whitespace position once we've
        // accumulated minWords words AND the minChars floor is met.
        var wordCount = 0
        var inWord = false
        var i = start
        while i < buffer.count {
            let c = buffer[i]
            if c.isWhitespace {
                if inWord {
                    wordCount += 1
                    inWord = false
                    if wordCount >= minWords, (i + 1) - start >= minChars {
                        // Boundary lands AFTER the whitespace so the
                        // next slice starts on the next word — same
                        // convention the sentence cutter uses.
                        return i + 1
                    }
                }
            } else if !inWord {
                inWord = true
            }
            i += 1
        }
        return nil
    }
}
