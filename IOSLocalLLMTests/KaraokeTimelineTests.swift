import SwiftUI
import XCTest
@testable import IOSLocalLLM

final class KaraokeTimelineTests: XCTestCase {

    func testPhraseBuilderGroupsWords() {
        let words: [SpeechWordTiming] = (0..<12).map { i in
            SpeechWordTiming(
                word: i == 2 ? "one," : "w\(i)",
                startTime: Double(i) * 0.2,
                endTime: Double(i) * 0.2 + 0.18,
                utf16Range: NSRange(location: i * 3, length: 2)
            )
        }
        let seg = SpeechSegment(
            text: "group",
            startTime: 0,
            endTime: 2.4,
            words: words,
            timingSource: .estimated
        )
        let timeline = KaraokePhraseBuilder.build(from: [seg])
        XCTAssertFalse(timeline.phrases.isEmpty)
        XCTAssertLessThan(timeline.phrases.count, words.count)
        // Binary search finds a phrase mid-stream.
        XCTAssertNotNil(timeline.phraseIndex(at: 1.0))
        let idx0 = timeline.phraseIndex(at: 0.05)
        let idx1 = timeline.phraseIndex(at: 2.0)
        XCTAssertNotNil(idx0)
        XCTAssertNotNil(idx1)
        if let a = idx0, let b = idx1 {
            XCTAssertLessThanOrEqual(a, b)
        }
    }

    func testNeverMovesToEarlierPhraseIndexConceptually() {
        let phrases = [
            KaraokePhrase(text: "a", startTime: 0, endTime: 0.6, utf16Range: NSRange(location: 0, length: 1)),
            KaraokePhrase(text: "b", startTime: 0.6, endTime: 1.2, utf16Range: NSRange(location: 2, length: 1)),
            KaraokePhrase(text: "c", startTime: 1.2, endTime: 1.8, utf16Range: NSRange(location: 4, length: 1))
        ]
        let timeline = KaraokeTimeline(phrases: phrases)
        XCTAssertEqual(timeline.phraseIndex(at: 0.3), 0)
        XCTAssertEqual(timeline.phraseIndex(at: 0.9), 1)
        XCTAssertEqual(timeline.phraseIndex(at: 1.5), 2)
        XCTAssertEqual(timeline.nextBoundary(after: 0.3), 0.6)
    }

    func testSpokenEndIsMonotonicWithTime() {
        let phrases = [
            KaraokePhrase(text: "hello", startTime: 0, endTime: 0.8, utf16Range: NSRange(location: 0, length: 5)),
            KaraokePhrase(text: "world", startTime: 0.8, endTime: 1.6, utf16Range: NSRange(location: 6, length: 5))
        ]
        let timeline = KaraokeTimeline(phrases: phrases)
        let early = timeline.spokenUTF16End(at: 0.2, transcriptLength: 11)
        let late = timeline.spokenUTF16End(at: 1.4, transcriptLength: 11)
        XCTAssertLessThanOrEqual(early, late)
    }

    func testWordlessSegmentsInsertSpaceBetweenRanges() {
        let segments = [
            SpeechSegment(
                text: "Hello",
                startTime: 0,
                endTime: 0.5,
                words: [],
                timingSource: .phraseLevel
            ),
            SpeechSegment(
                text: "world",
                startTime: 0.5,
                endTime: 1.0,
                words: [],
                timingSource: .phraseLevel
            )
        ]
        let timeline = KaraokePhraseBuilder.build(from: segments)
        XCTAssertEqual(timeline.phrases.count, 2)
        XCTAssertEqual(timeline.phrases[0].utf16Range.location, 0)
        XCTAssertEqual(timeline.phrases[0].utf16Range.length, 5)
        // Second phrase starts after an assumed separator so it maps into
        // "Hello world" rather than overlapping "Helloworld".
        XCTAssertEqual(timeline.phrases[1].utf16Range.location, 6)
        XCTAssertEqual(timeline.phrases[1].utf16Range.length, 5)
    }

    func testPhraseLevelWordCarriesUTF16BaseOffset() {
        let base = 12
        let text = "Next sentence."
        let seg = SpeechSegment(
            text: text,
            startTime: 1.0,
            endTime: 2.0,
            words: [
                SpeechWordTiming(
                    word: text,
                    startTime: 1.0,
                    endTime: 2.0,
                    utf16Range: NSRange(location: base, length: (text as NSString).length)
                )
            ],
            timingSource: .phraseLevel
        )
        let timeline = KaraokePhraseBuilder.build(from: [seg])
        XCTAssertEqual(timeline.phrases.first?.utf16Range.location, base)
        XCTAssertEqual(timeline.phrases.first?.utf16Range.length, (text as NSString).length)
    }

    // MARK: - Transcript = what is spoken

    func testStreamedChunksAppendOnceAndARepeatedSentenceGetsItsOwnSpot() {
        var transcript = ""
        var cursor = 0
        let first = SpeechPlaybackCoordinator.placeChunk("Sure! Paris is the capital.", in: &transcript, cursor: &cursor)
        let second = SpeechPlaybackCoordinator.placeChunk("Yes.", in: &transcript, cursor: &cursor)
        let third = SpeechPlaybackCoordinator.placeChunk("Yes.", in: &transcript, cursor: &cursor)
        XCTAssertEqual(transcript, "Sure! Paris is the capital. Yes. Yes.")
        XCTAssertEqual(first, 0)
        XCTAssertGreaterThan(third, second)   // not matched back onto the first "Yes."
        XCTAssertEqual((transcript as NSString).substring(from: third), "Yes.")
    }

    func testSeededTranscriptMapsNormalizedChunksInOrderWithoutGrowing() {
        // Paragraph break + a repeated sentence: the raw text never matched the
        // chunker's output, so every such chunk used to be appended again.
        let raw = "First paragraph here.\n\nSecond paragraph here. First paragraph here."
        let chunks = TextChunker.chunks(from: raw, config: .init(maxChunkLength: 30))
        XCTAssertEqual(chunks.count, 3)
        var transcript = chunks.joined(separator: " ")
        let seeded = transcript
        var cursor = 0
        var last = -1
        for chunk in chunks {
            let location = SpeechPlaybackCoordinator.placeChunk(chunk, in: &transcript, cursor: &cursor)
            XCTAssertGreaterThan(location, last)
            last = location
        }
        XCTAssertEqual(transcript, seeded)
    }

    // MARK: - Word-by-word fill

    func testSpokenEndStepsWordByWord() {
        let words = [("one", 0.0, 0, 3), ("two", 0.5, 4, 3), ("three.", 1.0, 8, 6)].map {
            SpeechWordTiming(word: $0.0, startTime: $0.1, endTime: $0.1 + 0.5,
                             utf16Range: NSRange(location: $0.2, length: $0.3))
        }
        let phrase = KaraokePhrase(text: "one two three.", startTime: 0, endTime: 1.5,
                                   utf16Range: NSRange(location: 0, length: 14))
        let track = KaraokeCueTrack.from(phrases: [phrase], sampleRate: 1000, timingSource: .estimated, words: words)
        XCTAssertEqual(track.spokenUTF16End(at: 0, transcriptLength: 14), 3)     // lit from its first sample
        XCTAssertEqual(track.spokenUTF16End(at: 499, transcriptLength: 14), 3)   // never splits a word
        XCTAssertEqual(track.spokenUTF16End(at: 500, transcriptLength: 14), 7)
        XCTAssertEqual(track.spokenUTF16End(at: 1_200, transcriptLength: 14), 14)
    }

    func testOnlySpokenWordsOfTheActivePhraseTurnAccent() {
        // "one" was spoken earlier; the phrase "two three" is active and "two" has started.
        let attr = KaraokeTextBuilder.build(
            text: "one two three four",
            spokenUTF16End: 7,
            activeRange: NSRange(location: 4, length: 9),
            ink: .red,
            inkSecondary: .gray,
            accent: .blue
        )
        func color(at location: Int) -> Color? {
            Range(NSRange(location: location, length: 1), in: attr).flatMap { attr[$0].swiftUI.foregroundColor }
        }
        XCTAssertEqual(color(at: 0), .red)     // spoken, before the phrase
        XCTAssertEqual(color(at: 4), .blue)    // spoken, inside the phrase
        XCTAssertEqual(color(at: 8), .gray)    // in the phrase, not spoken yet
        XCTAssertEqual(color(at: 14), .gray)   // not reached
    }

    func testAlignedWordsKeepPunctuationSoPhrasesCloseOnIt() {
        let text = "Hello there, my friend. How are you doing today? I am fine."
        let source = PredDurWordAligner.extractSourceWords(from: text)
        XCTAssertEqual(source.count, 12)   // still exactly one entry per word
        let words = source.enumerated().map { index, word in
            SpeechWordTiming(word: word.text, startTime: Double(index) * 0.3, endTime: Double(index) * 0.3 + 0.3,
                             utf16Range: word.utf16Range)
        }
        let segment = SpeechSegment(text: text, startTime: 0, endTime: 3.6, words: words, timingSource: .engineDerived)
        let ns = text as NSString
        let phrases = KaraokePhraseBuilder.build(from: [segment]).phrases.map { ns.substring(with: $0.utf16Range) }
        XCTAssertEqual(phrases, ["Hello there,", "my friend.", "How are you", "doing today?", "I am fine."])
    }
}
