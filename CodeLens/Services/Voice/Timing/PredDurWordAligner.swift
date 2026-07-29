import Foundation

// MARK: - PredDurWordAligner
// Maps Kitten CoreML `pred_dur` (frames per input token) onto source words.
// Framing pads / EOU and inter-word spaces become pauses.

enum PredDurWordAligner {

    struct SourceWord: Equatable, Sendable {
        let text: String
        let utf16Range: NSRange
    }

    enum TokenKind: Equatable, Sendable {
        case framing
        case spaceOrPunct
        case phoneme(wordIndex: Int)
    }

    struct AlignmentToken: Equatable, Sendable {
        let kind: TokenKind
    }

    /// Build word list + per-phoneme-token kinds for a Kitten-framed sequence.
    static func tokens(
        for text: String,
        phonemeIDs: [Int32],
        phonemizer: PhonemizerEN = .shared
    ) -> (words: [SourceWord], tokens: [AlignmentToken]) {
        let words = extractSourceWords(from: text)
        let phonemeChars = phonemizer.phonemeCharacters(for: text)
        // Reconstruct framed sequence kinds: pad + chars + eou + pad
        var kinds: [AlignmentToken] = []
        kinds.append(AlignmentToken(kind: .framing)) // leading pad

        var wordCursor = 0
        var inWord = false
        for ch in phonemeChars {
            if ch == " " {
                kinds.append(AlignmentToken(kind: .spaceOrPunct))
                inWord = false
                continue
            }
            if Self.isVocabPunctuation(ch) {
                kinds.append(AlignmentToken(kind: .spaceOrPunct))
                inWord = false
                continue
            }
            if !inWord {
                // Advance word cursor to next real word if needed.
                while wordCursor < words.count,
                      words[wordCursor].text.unicodeScalars.allSatisfy({ !$0.properties.isAlphabetic && $0 != "'" }) {
                    wordCursor += 1
                }
                inWord = true
            }
            let idx = min(wordCursor, max(words.count - 1, 0))
            kinds.append(AlignmentToken(kind: .phoneme(wordIndex: max(0, idx))))
        }
        // Close last word
        _ = inWord
        kinds.append(AlignmentToken(kind: .framing)) // …
        kinds.append(AlignmentToken(kind: .framing)) // trailing pad

        // If phonemeIDs length differs (truncation), clip kinds to match.
        if kinds.count > phonemeIDs.count {
            kinds = Array(kinds.prefix(phonemeIDs.count))
        } else {
            while kinds.count < phonemeIDs.count {
                kinds.append(AlignmentToken(kind: .framing))
            }
        }

        // Improve word cursor: assign phoneme runs between spaces to sequential words.
        return refineWordAssignment(words: words, tokens: kinds, phonemeChars: phonemeChars)
    }

    /// Convert pred_dur frames into word timings.
    static func align(
        text: String,
        phonemeIDs: [Int32],
        predDurFrames: [Float],
        validTokenCount: Int,
        audioDuration: TimeInterval,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int,
        phonemizer: PhonemizerEN = .shared
    ) -> SpeechAlignmentResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, audioDuration > 0.01 else { return nil }

        let count = min(validTokenCount, predDurFrames.count, phonemeIDs.count)
        guard count > 0 else { return nil }

        let (words, tokenKinds) = tokens(for: trimmed, phonemeIDs: Array(phonemeIDs.prefix(count)), phonemizer: phonemizer)
        guard !words.isEmpty else { return nil }

        let frames = predDurFrames.prefix(count).map { max(0, $0) }
        let totalFrames = frames.reduce(0, +)
        guard totalFrames > 0.5 else { return nil }

        // Derive hop from actual PCM so we don't hard-code 600.
        let secondsPerFrame = audioDuration / Double(totalFrames)

        var wordDurations = Array(repeating: 0.0, count: words.count)
        var leadingPause = 0.0
        var trailingPauses = Array(repeating: 0.0, count: words.count)

        var lastWord = -1
        for i in 0..<count {
            let seconds = Double(frames[i]) * secondsPerFrame
            let kind = i < tokenKinds.count ? tokenKinds[i].kind : .framing
            switch kind {
            case .framing:
                if lastWord < 0 { leadingPause += seconds }
                else { trailingPauses[lastWord] += seconds }
            case .spaceOrPunct:
                if lastWord >= 0 { trailingPauses[lastWord] += seconds }
                else { leadingPause += seconds }
            case .phoneme(let wi):
                let idx = min(max(wi, 0), words.count - 1)
                wordDurations[idx] += seconds
                lastWord = idx
            }
        }

        // Build timings; attach pauses after each word (punctuation).
        var cursor = timelineOffset + leadingPause
        var timings: [SpeechWordTiming] = []
        timings.reserveCapacity(words.count)
        for i in 0..<words.count {
            let speak = max(wordDurations[i], 0.04)
            let pause = trailingPauses[i]
            let start = cursor
            let end = start + speak + pause
            let range = NSRange(
                location: utf16BaseOffset + words[i].utf16Range.location,
                length: words[i].utf16Range.length
            )
            timings.append(
                SpeechWordTiming(
                    word: words[i].text,
                    startTime: start,
                    endTime: end,
                    utf16Range: range
                )
            )
            cursor = end
        }

        // Clamp / correct drift against measured audio duration.
        let targetEnd = timelineOffset + audioDuration
        if let last = timings.last, abs(last.endTime - targetEnd) > 0.001 {
            let span = max(last.endTime - timelineOffset, 0.001)
            let scale = (targetEnd - timelineOffset) / span
            timings = timings.map { w in
                SpeechWordTiming(
                    id: w.id,
                    word: w.word,
                    startTime: timelineOffset + (w.startTime - timelineOffset) * scale,
                    endTime: timelineOffset + (w.endTime - timelineOffset) * scale,
                    utf16Range: w.utf16Range
                )
            }
        }

        guard validate(timings: timings, audioDuration: audioDuration, timelineOffset: timelineOffset) else {
            return nil
        }

        let segment = SpeechSegment(
            text: trimmed,
            startTime: timelineOffset,
            endTime: timelineOffset + audioDuration,
            words: timings,
            timingSource: .engineDerived
        )
        return SpeechAlignmentResult(
            segments: [segment],
            accuracy: .engineDerived,
            diagnosticDetail: "Kitten pred_dur"
        )
    }

    // MARK: - Source words

    static func extractSourceWords(from text: String) -> [SourceWord] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}'’]+|[^\s\p{L}\p{N}]"#, options: []) else {
            return []
        }
        return regex.matches(in: text, options: [], range: full).compactMap { match in
            let range = match.range
            guard range.length > 0 else { return nil }
            let raw = ns.substring(with: range)
            // Skip pure punctuation tokens for word karaoke (pauses absorb them).
            let isWord = raw.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            guard isWord else { return nil }
            return SourceWord(text: raw, utf16Range: range)
        }
    }

    private static func refineWordAssignment(
        words: [SourceWord],
        tokens: [AlignmentToken],
        phonemeChars: [Character]
    ) -> (words: [SourceWord], tokens: [AlignmentToken]) {
        guard !words.isEmpty else { return (words, tokens) }
        // Re-walk phoneme chars and assign sequential word indices between spaces.
        var refined: [AlignmentToken] = []
        refined.append(AlignmentToken(kind: .framing))
        var wordIndex = 0
        var expectingWord = true
        for ch in phonemeChars {
            if ch == " " || isVocabPunctuation(ch) {
                refined.append(AlignmentToken(kind: .spaceOrPunct))
                if !expectingWord { wordIndex = min(wordIndex + 1, words.count - 1) }
                expectingWord = true
                continue
            }
            refined.append(AlignmentToken(kind: .phoneme(wordIndex: min(wordIndex, words.count - 1))))
            expectingWord = false
        }
        refined.append(AlignmentToken(kind: .framing))
        refined.append(AlignmentToken(kind: .framing))
        if refined.count != tokens.count {
            return (words, tokens)
        }
        return (words, refined)
    }

    private static func isVocabPunctuation(_ ch: Character) -> Bool {
        ";:,.!?¡¿—…\"«»".contains(ch)
    }

    static func validate(
        timings: [SpeechWordTiming],
        audioDuration: TimeInterval,
        timelineOffset: TimeInterval
    ) -> Bool {
        guard !timings.isEmpty else { return false }
        var previousStart = timelineOffset - 0.0001
        let limit = timelineOffset + audioDuration + 0.05
        for w in timings {
            if w.startTime < timelineOffset - 0.001 { return false }
            if w.endTime + 0.001 < w.startTime { return false }
            if w.endTime > limit { return false }
            if w.startTime + 0.001 < previousStart { return false }
            if w.endTime - w.startTime < 0.02 { return false }
            previousStart = w.startTime
        }
        return true
    }
}

// MARK: - PhonemizerEN helpers

extension PhonemizerEN {
    /// Exposes the unframed phoneme character stream for alignment.
    func phonemeCharacters(for text: String) -> [Character] {
        // Mirror private phonemes(for:) via phonemeString.
        Array(phonemeString(for: text))
    }
}
