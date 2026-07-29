import Foundation

// MARK: - ReasoningStripper
//
// Streaming-safe filter that removes chain-of-thought blocks from text
// destined for TTS. Models like Qwen3 emit `<think>...</think>` blocks
// when thinking mode is on; the reply UI shows them intact so the user
// can inspect the model's reasoning, but the TTS branch must NOT speak
// the chain-of-thought aloud.
//
// Two consumption modes:
//
//   • Streaming — instantiate one stripper, feed it token chunks via
//     `feed(_:)` as they arrive from the LLM, read filtered text out
//     of each call. The instance buffers across calls so an open tag
//     in chunk A and the matching close tag in chunk B are stripped
//     together, not leaked piecewise.
//
//   • One-shot — call `strip(_:)` on a complete string. Used by the
//     non-streaming code paths (analysis-panel auto-read, Lens
//     speak-on-final, "read aloud" button) so the reasoning filter
//     applies everywhere TTS does, not just live streaming.
//
// Configurable open/close patterns. Default is `<think>` / `</think>`
// (Qwen3 family). Future models with `<reasoning>` / `[THINKING]` /
// other delimiters work by instantiating with custom patterns — no
// code change in this file or in callers.
//
// Edge cases handled:
//   • Open tag split across chunks (`<thi` + `nk>...`) — emit-decision
//     defers until the tag completes or is disproved.
//   • Multiple think blocks in one stream — re-enters cleanly.
//   • Unclosed block at stream end — `flush()` drops the partial.
//   • `<th<think>x</think>` — the broken-prefix `<th` is emitted as
//     plain text and the fresh `<think>...` is stripped correctly.
//     The mismatch-recovery walks every suffix of the broken match,
//     longest first, so any suffix that is also a prefix of the tag
//     becomes the new buffer (KMP failure-function in spirit).
//   • No think blocks — bytes pass through unchanged (modulo the
//     buffering deferral for legitimate partial-open candidates).

final class ReasoningStripper {

    // MARK: - Configuration

    /// Opening delimiter to match (default `<think>`).
    let openTag: String
    /// Closing delimiter to match (default `</think>`).
    let closeTag: String

    // MARK: - State (streaming)

    /// Characters held back that form a prefix of `openTag`. While
    /// non-empty AND we're not inside a block, the buffer either
    /// completes into `openTag` (drop and enter `.inside`) or is
    /// disproved (flush as legitimate output, then re-evaluate).
    private var pendingPrefix: [Character] = []

    /// Same idea but for the close tag while inside a block. Buffered
    /// chars are dropped when complete (it WAS the close tag) and
    /// also dropped when disproved (we're still inside the block, so
    /// the content stays suppressed either way).
    private var pendingCloseCandidate: [Character] = []

    /// True while we're between a matched `openTag` and the next
    /// matched `closeTag`. While true, all output is suppressed.
    private var inside: Bool = false

    // MARK: - Init

    init(openTag: String = "<think>", closeTag: String = "</think>") {
        precondition(!openTag.isEmpty, "openTag must be non-empty")
        precondition(!closeTag.isEmpty, "closeTag must be non-empty")
        self.openTag = openTag
        self.closeTag = closeTag
    }

    // MARK: - Streaming API

    /// Feeds a chunk of streamed text through the filter. Returns the
    /// portion safe to forward to TTS. Buffered material is held for
    /// the next call (or `flush()`).
    func feed(_ chunk: String) -> String {
        guard !chunk.isEmpty else { return "" }
        var out = ""
        out.reserveCapacity(chunk.count)
        for ch in chunk {
            if inside {
                ingestInside(ch, into: &out)
            } else {
                ingestOutside(ch, into: &out)
            }
        }
        return out
    }

    /// Signals end-of-stream. A pending partial open-tag candidate
    /// that never completed is flushed as output (it was always
    /// legitimate text we deferred). An unclosed `inside` block is
    /// dropped — the user-visible reply branch still has the full
    /// text, so we just keep the audio clean.
    func flush() -> String {
        defer {
            pendingPrefix.removeAll()
            pendingCloseCandidate.removeAll()
            inside = false
        }
        if !inside {
            return String(pendingPrefix)
        }
        return ""
    }

    // MARK: - One-shot
    //
    // Used by every non-streaming TTS entry point so the reasoning
    // filter applies everywhere audio is produced, not just to the
    // live conversation stream. Pure function; safe on any thread.

    /// Strips think blocks from `text` using default tags.
    static func strip(_ text: String) -> String {
        strip(text, openTag: "<think>", closeTag: "</think>")
    }

    /// Strips blocks defined by custom open/close tags.
    static func strip(_ text: String, openTag: String, closeTag: String) -> String {
        let s = ReasoningStripper(openTag: openTag, closeTag: closeTag)
        return s.feed(text) + s.flush()
    }

    // MARK: - State machine
    //
    // Mismatch recovery walks every suffix of the broken-match buffer
    // (longest first) and re-keys the buffer to the longest suffix
    // that is itself a prefix of the tag. KMP-style — handles
    // pathological tag shapes like `ababc` correctly while costing
    // nothing for short well-formed tags.

    private func ingestOutside(_ ch: Character, into out: inout String) {
        let candidate = pendingPrefix + [ch]
        if hasPrefix(openTag, candidate) {
            if candidate.count == openTag.count {
                pendingPrefix.removeAll()
                inside = true
            } else {
                pendingPrefix = candidate
            }
            return
        }
        // Broke the open-tag prefix. Re-key the buffer to the longest
        // suffix of `candidate` that is a prefix of openTag — that's
        // where matching restarts. Chars before that suffix are
        // decided-safe output.
        for start in 1 ..< candidate.count {
            let suffix = Array(candidate[start...])
            if hasPrefix(openTag, suffix) {
                out.append(contentsOf: candidate[..<start])
                if suffix.count == openTag.count {
                    pendingPrefix.removeAll()
                    inside = true
                } else {
                    pendingPrefix = suffix
                }
                return
            }
        }
        // No salvageable suffix — emit everything, buffer clears.
        out.append(contentsOf: candidate)
        pendingPrefix.removeAll()
    }

    private func ingestInside(_ ch: Character, into out: inout String) {
        let candidate = pendingCloseCandidate + [ch]
        if hasPrefix(closeTag, candidate) {
            if candidate.count == closeTag.count {
                pendingCloseCandidate.removeAll()
                inside = false
            } else {
                pendingCloseCandidate = candidate
            }
            return
        }
        // Broke the close-tag prefix. Re-key the buffer the same way
        // — find the longest suffix of `candidate` that's a prefix of
        // closeTag. Anything before is just block content (still
        // dropped). Inside-state output stays suppressed throughout.
        for start in 1 ..< candidate.count {
            let suffix = Array(candidate[start...])
            if hasPrefix(closeTag, suffix) {
                if suffix.count == closeTag.count {
                    pendingCloseCandidate.removeAll()
                    inside = false
                } else {
                    pendingCloseCandidate = suffix
                }
                return
            }
        }
        pendingCloseCandidate.removeAll()
    }

    /// True when `chars` is a prefix of `tag` (compared as Characters).
    /// Specialised for our short-tag case so we don't pay String
    /// bridging for every step of the state machine.
    private func hasPrefix(_ tag: String, _ chars: [Character]) -> Bool {
        guard chars.count <= tag.count else { return false }
        var t = tag.makeIterator()
        for c in chars {
            guard let tc = t.next(), tc == c else { return false }
        }
        return true
    }
}
