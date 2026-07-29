import Foundation

// MARK: - AudioQueue
//
// Producer-consumer queue for streaming TTS utterances. Lifted from
// `StreamingSpeechSession` (which used to live inside VoiceService.swift)
// and renamed to match the pipeline naming convention; behavior is
// preserved verbatim with two additions:
//
//   1. Three @Published properties (`isSpeaking`, `queueDepth`,
//      `currentLanguage`) update automatically as the consumer pulls
//      utterances. Session 3 (Lens streaming TTS) binds the status
//      pill against these without going through VoiceService.
//
//   2. `drainPending()` — drops the pending queue but lets the
//      currently-playing utterance finish naturally. Distinct from
//      `finish()` (which drains EVERYTHING to completion) and `stop()`
//      (which cuts current and pending immediately).
//
// Hard rules carried forward from session 1's audit:
//
//   • `stop()` is SYNCHRONOUS and IMMEDIATE — no fadeout. The
//     `streamGeneration` cancellation contract in `VoiceService.stop`
//     relies on stale `defer { isPlaying = false }` blocks not racing
//     a fresh utterance. Adding any async delay here would re-open
//     the "zombie voice" failure mode the audit explicitly called
//     out.
//
//   • `enqueue` does NOT interrupt current playback. Consumers see a
//     new item only after they finish the current one (via `next()`).

@MainActor
final class AudioQueue: ObservableObject {

    // MARK: - Observable state
    //
    // Updated as a side effect of `next()` / `stop()` / `finish()` so
    // consumers don't have to maintain parallel UI bindings. Existing
    // `VoiceService.isPlaying` stays in place for back-compat with
    // the many UI sites already bound to it; AudioQueue's state is
    // the pipeline-level view for new (Lens) and future surfaces.

    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var queueDepth: Int = 0
    /// BCP-47 tag of the currently-playing utterance, set when
    /// `next()` returns a non-nil value with `language` populated.
    /// `nil` when no utterance is playing or the playing utterance
    /// had no language tag.
    @Published private(set) var currentLanguage: String? = nil

    // MARK: - Utterance

    /// One queued unit of speech. `language` is an optional BCP-47
    /// tag (e.g. `en-US`, `tr-TR`) — when set, the consumer picks a
    /// voice that matches. `engineHint` lets a caller force a
    /// specific engine for this utterance, bypassing the per-chunk
    /// router; nil means "use the router."
    struct Utterance: Equatable {
        let text: String
        let language: String?
        let engineHint: VoiceEngineKind?

        init(text: String, language: String? = nil, engineHint: VoiceEngineKind? = nil) {
            self.text = text
            self.language = language
            self.engineHint = engineHint
        }
    }

    // MARK: - Internal queue state

    private var pending: [Utterance] = []
    private var inputFinished = false
    private var cancelled = false
    private var waiter: CheckedContinuation<Utterance?, Never>?

    // MARK: - Producer API

    /// Enqueue an utterance. Does NOT interrupt the currently-playing
    /// chunk. Empty / whitespace-only text is dropped silently so
    /// callers can be lazy about trimming.
    func enqueue(_ utterance: Utterance) {
        guard !cancelled, !inputFinished else { return }
        let trimmed = utterance.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = Utterance(
            text: trimmed,
            language: utterance.language,
            engineHint: utterance.engineHint
        )
        if let w = waiter {
            waiter = nil
            w.resume(returning: normalized)
        } else {
            pending.append(normalized)
            queueDepth = pending.count
        }
    }

    /// Signal that no more utterances will be enqueued. The consumer
    /// drains the pending queue then exits with `nil`. Used at end
    /// of LLM generation so the trailing sentence still plays.
    func finish() {
        guard !inputFinished else { return }
        inputFinished = true
        if pending.isEmpty, let w = waiter {
            waiter = nil
            w.resume(returning: nil)
        }
    }

    /// Drop the PENDING queue but let the currently-playing utterance
    /// finish naturally. No current caller — kept for session 3
    /// scenarios where the user dismisses a Lens caption but the
    /// current sentence should still finish. Setting `inputFinished`
    /// means `next()` returns nil once the consumer is ready for it,
    /// without forcing a hard cancel.
    func drainPending() {
        pending.removeAll()
        queueDepth = 0
        inputFinished = true
        // Don't touch cancelled / isSpeaking — the current chunk is
        // still allowed to finish. The waiter is also untouched: if
        // the consumer is mid-await, finish() telling it nil is
        // semantically the same (no more chunks coming).
        if let w = waiter {
            waiter = nil
            w.resume(returning: nil)
        }
    }

    /// Stop immediately. Drops everything including the current
    /// utterance, unblocks any awaiting consumer with `nil`. Sync.
    /// No fadeout — the cancellation contract requires this.
    func stop() {
        cancelled = true
        inputFinished = true
        pending.removeAll()
        queueDepth = 0
        if isSpeaking { isSpeaking = false }
        if currentLanguage != nil { currentLanguage = nil }
        if let w = waiter {
            waiter = nil
            w.resume(returning: nil)
        }
    }

    // MARK: - Consumer API

    /// Pull the next utterance, suspending if none is pending. Returns
    /// `nil` when the queue is exhausted (`finish` called + drained,
    /// `drainPending` called, or `stop` called).
    ///
    /// Side effects: updates `isSpeaking` + `currentLanguage` so
    /// observers see the right state without the consumer having to
    /// poke them manually.
    func next() async -> Utterance? {
        if cancelled { return nil }
        if !pending.isEmpty {
            let item = pending.removeFirst()
            queueDepth = pending.count
            markStartedPlaying(item)
            return item
        }
        if inputFinished {
            markStoppedPlaying()
            return nil
        }
        let item: Utterance? = await withCheckedContinuation { c in
            self.waiter = c
        }
        if let item {
            markStartedPlaying(item)
        } else {
            markStoppedPlaying()
        }
        return item
    }

    // MARK: - Internal state hooks

    private func markStartedPlaying(_ utterance: Utterance) {
        if !isSpeaking { isSpeaking = true }
        if currentLanguage != utterance.language {
            currentLanguage = utterance.language
        }
    }

    private func markStoppedPlaying() {
        if isSpeaking { isSpeaking = false }
        if currentLanguage != nil { currentLanguage = nil }
    }
}
