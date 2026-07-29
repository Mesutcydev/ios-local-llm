import Foundation

// MARK: - SpeechTimingProvider
// Capability-based timing. Engines without exact word timestamps use
// duration-weighted estimation (Level C). Chunk/phrase highlighting is
// Level D when only segment bounds are known.

protocol SpeechTimingProvider: Sendable {
    func timings(
        for text: String,
        audioDuration: TimeInterval?,
        engineCapabilities: TTSEngineCapabilities,
        timelineOffset: TimeInterval,
        utf16BaseOffset: Int
    ) async throws -> [SpeechSegment]
}

enum SpeechTimingError: Error, Equatable {
    case emptyText
    case invalidDuration
}

/// Duration-weighted word timing with punctuation pauses.
/// Marked `.estimated` so UI never pretends these are engine-exact.
struct EstimatedSpeechTimingProvider: SpeechTimingProvider, Sendable {

    static let shared = EstimatedSpeechTimingProvider()

    func timings(
        for text: String,
        audioDuration: TimeInterval?,
        engineCapabilities: TTSEngineCapabilities,
        timelineOffset: TimeInterval = 0,
        utf16BaseOffset: Int = 0
    ) async throws -> [SpeechSegment] {
        // Exact-word engines would short-circuit here; none of our shipping
        // engines expose timestamps today (Apple is offline-rendered).
        _ = engineCapabilities.intersection(.exactWordTimings)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechTimingError.emptyText }

        let duration = max(audioDuration ?? estimatedDuration(for: trimmed), 0.05)
        let tokens = tokenize(trimmed)
        let source: SpeechTimingSource = .estimated

        guard !tokens.isEmpty else {
            let local = NSRange(location: 0, length: (trimmed as NSString).length)
            let word = SpeechWordTiming(
                word: trimmed,
                startTime: timelineOffset,
                endTime: timelineOffset + duration,
                utf16Range: NSRange(location: utf16BaseOffset + local.location, length: local.length)
            )
            return [
                SpeechSegment(
                    text: trimmed,
                    startTime: timelineOffset,
                    endTime: timelineOffset + duration,
                    words: [word],
                    timingSource: source
                )
            ]
        }

        let weights = tokens.map { tokenWeight($0) }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { throw SpeechTimingError.invalidDuration }

        let pauseBudget = min(duration * 0.22, tokens.reduce(0) { $0 + pauseDuration(for: $1) })
        let speakBudget = max(duration - pauseBudget, duration * 0.55)

        var cursor = timelineOffset
        var words: [SpeechWordTiming] = []
        words.reserveCapacity(tokens.count)

        for (token, weight) in zip(tokens, weights) {
            let speakShare = speakBudget * (weight / totalWeight)
            let pause = min(
                pauseDuration(for: token),
                pauseBudget / Double(max(tokens.count, 1))
            )
            let start = cursor
            let end = start + speakShare + pause
            words.append(
                SpeechWordTiming(
                    word: token.text,
                    startTime: start,
                    endTime: end,
                    utf16Range: NSRange(
                        location: utf16BaseOffset + token.utf16Range.location,
                        length: token.utf16Range.length
                    )
                )
            )
            cursor = end
        }

        // Correct drift so the last word ends at measured PCM duration.
        let targetEnd = timelineOffset + duration
        if let last = words.last, abs(last.endTime - targetEnd) > 0.001 {
            let span = max(last.endTime - timelineOffset, 0.001)
            let scale = (targetEnd - timelineOffset) / span
            words = words.map { w in
                SpeechWordTiming(
                    id: w.id,
                    word: w.word,
                    startTime: timelineOffset + (w.startTime - timelineOffset) * scale,
                    endTime: timelineOffset + (w.endTime - timelineOffset) * scale,
                    utf16Range: w.utf16Range
                )
            }
        }

        return [
            SpeechSegment(
                text: trimmed,
                startTime: timelineOffset,
                endTime: timelineOffset + duration,
                words: words,
                timingSource: source
            )
        ]
    }

    // MARK: - Tokenization

    struct Token: Equatable {
        let text: String
        let utf16Range: NSRange
        let trailingPunctuation: Character?
    }

    func tokenize(_ text: String) -> [Token] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: #"\S+"#, options: []) else {
            return []
        }

        var tokens: [Token] = []
        tokens.reserveCapacity(8)
        for match in regex.matches(in: text, options: [], range: full) {
            let range = match.range
            guard range.location != NSNotFound, range.length > 0 else { continue }
            let raw = ns.substring(with: range)
            var trailing: Character?
            if let last = raw.last, Self.pausePunctuation.contains(last) {
                trailing = last
            }
            tokens.append(Token(text: raw, utf16Range: range, trailingPunctuation: trailing))
        }
        return tokens
    }

    func tokenWeight(_ token: Token) -> Double {
        let letters = token.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let base = max(Double(letters), 1.5)
        return base + Double(max(token.text.count - letters, 0)) * 0.35
    }

    private static let pausePunctuation = Set<Character>(Array(",;:….!?،؛؟。！？"))

    func pauseDuration(for token: Token) -> TimeInterval {
        guard let p = token.trailingPunctuation else { return 0 }
        switch p {
        case ",", "،", ";": return 0.12
        case ":", "…": return 0.18
        case ".", "!", "?", "。", "！", "؟", "？": return 0.28
        default: return 0.08
        }
    }

    /// Rough spoken duration when no audio length is known yet.
    func estimatedDuration(for text: String) -> TimeInterval {
        let chars = Double((text as NSString).length)
        return max(0.35, chars / 14.0)
    }
}

// MARK: - Active-word mapping

enum SpeechProgressMapper {
    /// Maps absolute playback time into word / segment indices and UTF-16 ranges.
    /// Ranges on words are already absolute in the karaoke transcript.
    static func resolve(
        time: TimeInterval,
        segments: [SpeechSegment],
        transcriptUTF16Length: Int
    ) -> (segmentIndex: Int?, wordIndex: Int?, activeRange: NSRange?, spokenEnd: Int) {
        guard !segments.isEmpty, transcriptUTF16Length > 0 else {
            return (nil, nil, nil, 0)
        }

        var globalWordIndex = 0
        var spokenEnd = 0
        var activeSegment: Int?
        var activeWord: Int?
        var activeRange: NSRange?

        for (sIdx, segment) in segments.enumerated() {
            if time + 0.0001 < segment.startTime { break }
            activeSegment = sIdx

            if segment.words.isEmpty {
                if time >= segment.startTime {
                    let end = min(
                        (segment.text as NSString).length + spokenEnd,
                        transcriptUTF16Length
                    )
                    spokenEnd = max(spokenEnd, end)
                }
                globalWordIndex += 0
                continue
            }

            for word in segment.words {
                let range = clamped(word.utf16Range, length: transcriptUTF16Length)
                if time >= word.endTime - 0.0001 {
                    if let range {
                        spokenEnd = max(spokenEnd, range.location + range.length)
                    }
                    globalWordIndex += 1
                    continue
                }
                if time >= word.startTime - 0.0001 {
                    activeWord = globalWordIndex
                    activeRange = range
                    if let range {
                        spokenEnd = max(spokenEnd, range.location)
                    }
                    return (sIdx, activeWord, activeRange, min(spokenEnd, transcriptUTF16Length))
                }
                return (sIdx, nil, nil, min(spokenEnd, transcriptUTF16Length))
            }
        }

        if let last = segments.last, time >= last.endTime - 0.0001 {
            return (segments.count - 1, nil, nil, transcriptUTF16Length)
        }

        return (activeSegment, activeWord, activeRange, min(spokenEnd, transcriptUTF16Length))
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange? {
        guard length > 0, range.location >= 0 else { return nil }
        let loc = min(range.location, length)
        let len = min(range.length, max(0, length - loc))
        guard len > 0 else { return nil }
        return NSRange(location: loc, length: len)
    }
}
