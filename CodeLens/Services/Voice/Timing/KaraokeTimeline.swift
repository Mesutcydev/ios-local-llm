import Foundation

// MARK: - KaraokePhrase / KaraokeTimeline
// Phrase-indexed karaoke. Lookups are binary search — not per-word polling.

struct KaraokePhrase: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let utf16Range: NSRange

    init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        utf16Range: NSRange
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.utf16Range = utf16Range
    }
}

struct KaraokeTimeline: Sendable, Equatable {
    let phrases: [KaraokePhrase]

    static let empty = KaraokeTimeline(phrases: [])

    func phraseIndex(at time: TimeInterval) -> Int? {
        guard !phrases.isEmpty else { return nil }
        if time < phrases[0].startTime { return 0 }
        var lo = 0
        var hi = phrases.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let p = phrases[mid]
            if time < p.startTime {
                hi = mid - 1
            } else if time >= p.endTime {
                best = mid
                lo = mid + 1
            } else {
                return mid
            }
        }
        return min(best, phrases.count - 1)
    }

    func phrase(at time: TimeInterval) -> KaraokePhrase? {
        guard let idx = phraseIndex(at: time) else { return nil }
        return phrases[idx]
    }

    func nextBoundary(after time: TimeInterval) -> TimeInterval? {
        guard let idx = phraseIndex(at: time) else {
            return phrases.first?.startTime
        }
        let end = phrases[idx].endTime
        if time < end { return end }
        if idx + 1 < phrases.count { return phrases[idx + 1].startTime }
        return nil
    }

    func spokenUTF16End(at time: TimeInterval, transcriptLength: Int) -> Int {
        guard let idx = phraseIndex(at: time) else { return 0 }
        let phrase = phrases[idx]
        if time >= phrase.endTime - 0.02 {
            return min(transcriptLength, phrase.utf16Range.location + phrase.utf16Range.length)
        }
        // Mid-phrase: expose end of previous phrase as spoken floor.
        if idx == 0 { return phrase.utf16Range.location }
        let prev = phrases[idx - 1]
        return min(transcriptLength, prev.utf16Range.location + prev.utf16Range.length)
    }
}

// MARK: - Progressive alignment

struct ProgressiveSpeechAlignment: Sendable {
    let provisional: SpeechAlignmentResult
    let refined: Task<SpeechAlignmentResult?, Never>?
}

// MARK: - Phrase builder
// Groups words into 3–7 word / ~500–1200 ms phrases. Punctuation closes.

enum KaraokePhraseBuilder {
    static let minPhraseDuration: TimeInterval = 0.25
    static let targetMinDuration: TimeInterval = 0.50
    static let targetMaxDuration: TimeInterval = 1.20
    static let minWords = 3
    static let maxWords = 7

    static func build(from segments: [SpeechSegment]) -> KaraokeTimeline {
        let words = segments.flatMap(\.words)
        if words.isEmpty {
            // Phrase-level segments without words. Prefer any utf16 hints on
            // the segments themselves; otherwise place ranges with a single
            // space between chunks so they map into the speakable transcript
            // (concatenating lengths with no separator highlighted the wrong
            // span once karaoke text had spaces between sentences).
            var cursor = 0
            var rebuilt: [KaraokePhrase] = []
            for (index, seg) in segments.enumerated() {
                let len = (seg.text as NSString).length
                if index > 0 { cursor += 1 } // assume " " between chunks
                rebuilt.append(
                    KaraokePhrase(
                        text: seg.text,
                        startTime: seg.startTime,
                        endTime: max(seg.endTime, seg.startTime + minPhraseDuration),
                        utf16Range: NSRange(location: cursor, length: len)
                    )
                )
                cursor += len
            }
            return KaraokeTimeline(phrases: rebuilt)
        }

        var phrases: [KaraokePhrase] = []
        var batch: [SpeechWordTiming] = []

        func flush(force: Bool) {
            guard let firstWord = batch.first, let lastWord = batch.last else { return }
            let start = firstWord.startTime
            let end = lastWord.endTime
            let dur = end - start
            let count = batch.count
            let lastChar = lastWord.word.last
            let punctClose = lastChar.map { ".,!?;:".contains($0) } ?? false

            let longEnough = dur >= targetMinDuration || count >= minWords || punctClose || force
            let tooLong = dur >= targetMaxDuration || count >= maxWords
            guard longEnough || tooLong || force else { return }

            // Avoid tiny phrases unless final flush.
            if !force && dur < minPhraseDuration && count < minWords && !punctClose {
                return
            }

            let first = firstWord.utf16Range
            let last = lastWord.utf16Range
            let loc = first.location
            let len = max(0, (last.location + last.length) - loc)
            let text = batch.map(\.word).joined(separator: " ")
            phrases.append(
                KaraokePhrase(
                    text: text,
                    startTime: start,
                    endTime: max(end, start + (force ? 0 : 0)),
                    utf16Range: NSRange(location: loc, length: len)
                )
            )
            batch.removeAll(keepingCapacity: true)
        }

        for word in words {
            batch.append(word)
            guard let start = batch.first?.startTime else { continue }
            let dur = word.endTime - start
            let punctClose = word.word.last.map { ".,!?;:".contains($0) } ?? false
            if punctClose || batch.count >= maxWords || dur >= targetMaxDuration {
                flush(force: punctClose || batch.count >= maxWords || dur >= targetMaxDuration)
            } else if batch.count >= minWords && dur >= targetMinDuration {
                flush(force: false)
                // flush may no-op if still short; force when conditions met
                if let firstWord = batch.first,
                   let lastWord = batch.last,
                   batch.count >= minWords,
                   (lastWord.endTime - firstWord.startTime) >= targetMinDuration {
                    let first = firstWord.utf16Range
                    let last = lastWord.utf16Range
                    let loc = first.location
                    let len = max(0, (last.location + last.length) - loc)
                    phrases.append(
                        KaraokePhrase(
                            text: batch.map(\.word).joined(separator: " "),
                            startTime: firstWord.startTime,
                            endTime: lastWord.endTime,
                            utf16Range: NSRange(location: loc, length: len)
                        )
                    )
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        flush(force: true)

        // Merge accidental sub-250ms phrases into neighbors (except last).
        phrases = mergeShortPhrases(phrases)
        return KaraokeTimeline(phrases: phrases)
    }

    private static func mergeShortPhrases(_ input: [KaraokePhrase]) -> [KaraokePhrase] {
        guard input.count > 1 else { return input }
        var result: [KaraokePhrase] = []
        var i = 0
        while i < input.count {
            var current = input[i]
            while i + 1 < input.count,
                  (current.endTime - current.startTime) < minPhraseDuration {
                let next = input[i + 1]
                let loc = current.utf16Range.location
                let end = next.utf16Range.location + next.utf16Range.length
                current = KaraokePhrase(
                    id: current.id,
                    text: current.text + " " + next.text,
                    startTime: current.startTime,
                    endTime: next.endTime,
                    utf16Range: NSRange(location: loc, length: max(0, end - loc))
                )
                i += 1
            }
            result.append(current)
            i += 1
        }
        return result
    }
}
