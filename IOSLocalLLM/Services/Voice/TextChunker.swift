import Foundation

// MARK: - TextChunker
// Splits text into synthesis-friendly chunks.
//
// Design goals:
//  • Never cut mid-sentence.
//  • Honour code blocks — either skip them or label them "code block" summary.
//  • Keep chunks under ~250 characters so TTS engines aren't overloaded.
//  • Preserve paragraph structure for natural pacing.

struct TextChunker {

    // MARK: - Configuration

    struct Config {
        /// Maximum characters per chunk. Longer sentences are split at commas.
        var maxChunkLength: Int = 250
        /// When true, fenced code blocks (```) are replaced with a brief label.
        var summarizeCodeBlocks: Bool = false
        /// When true, raw code blocks are spoken character-by-character (not recommended).
        var readCodeVerbatim: Bool = false
    }

    // MARK: - Public API

    /// Splits `text` into an ordered array of speech-ready strings.
    static func chunks(from text: String, config: Config = Config()) -> [String] {
        let preprocessed = preprocess(text, config: config)
        let sentences = splitIntoSentences(preprocessed)
        return packIntoChunks(sentences, maxLength: config.maxChunkLength)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: - Preprocessing

    /// Strips markdown formatting and handles code blocks.
    private static func preprocess(_ text: String, config: Config) -> String {
        var result = text

        // Handle fenced code blocks
        let codeBlockPattern = "```[\\s\\S]*?```"
        if let regex = try? NSRegularExpression(pattern: codeBlockPattern) {
            let range = NSRange(result.startIndex..., in: result)
            if config.summarizeCodeBlocks {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: " [code block] "
                )
            } else if !config.readCodeVerbatim {
                // Skip code blocks by default
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: ""
                )
            }
        }

        // Strip markdown headers: ## Title → Title
        result = result.replacingOccurrences(of: #"^#{1,6}\s+"#,
                                              with: "",
                                              options: .regularExpression)

        // Strip markdown bold/italic: **bold** → bold
        result = result.replacingOccurrences(of: #"\*{1,2}([^*]+)\*{1,2}"#,
                                              with: "$1",
                                              options: .regularExpression)

        // Strip inline code: `symbol` → symbol
        result = result.replacingOccurrences(of: #"`([^`]+)`"#,
                                              with: "$1",
                                              options: .regularExpression)

        // Strip markdown links: [text](url) → text
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#,
                                              with: "$1",
                                              options: .regularExpression)

        // Collapse multiple blank lines
        result = result.replacingOccurrences(of: #"\n{3,}"#,
                                              with: "\n\n",
                                              options: .regularExpression)

        // Insert a period before paragraph breaks when the previous
        // line lacks terminal punctuation. Under-punctuating models
        // produce text like:
        //
        //     "First sentence
        //
        //     Second sentence."
        //
        // — without the inserted period the sentence splitter joins
        // both into one run-on chunk and TTS reads them as a single
        // breathless utterance. Matching the same terminators the
        // splitter looks for (`.?!`) plus a few full-width variants
        // keeps the rule consistent across Latin and CJK text.
        result = result.replacingOccurrences(
            of: #"([^\s\.!\?。!?])\n\n"#,
            with: "$1.\n\n",
            options: .regularExpression
        )

        return result
    }

    // MARK: - Sentence splitting

    /// Splits preprocessed text into individual sentences.
    private static func splitIntoSentences(_ text: String) -> [String] {
        // Split on paragraph boundaries first
        let paragraphs = text.components(separatedBy: "\n\n")

        var sentences: [String] = []
        for paragraph in paragraphs {
            let cleaned = paragraph
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }

            // Use NLTokenizer for sentence detection
            let detected = detectSentences(in: cleaned)
            sentences.append(contentsOf: detected)
        }
        return sentences
    }

    private static func detectSentences(in text: String) -> [String] {
        // Simple sentence splitter on ., !, ? followed by whitespace
        var sentences: [String] = []
        let pattern = #"(?<=[.!?])\s+"#

        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            var lastEnd = text.startIndex
            for match in regex.matches(in: text, range: range) {
                if let matchRange = Range(match.range, in: text) {
                    let sentence = String(text[lastEnd..<matchRange.lowerBound])
                    if !sentence.isEmpty { sentences.append(sentence) }
                    lastEnd = matchRange.upperBound
                }
            }
            let remaining = String(text[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(remaining)
            }
        } else {
            sentences = [text]
        }

        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Packing

    /// Packs sentences into chunks <= maxLength characters.
    private static func packIntoChunks(_ sentences: [String], maxLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count > maxLength {
                // Long sentence: flush current, then split long sentence at commas
                if !current.isEmpty { chunks.append(current); current = "" }
                let parts = splitAtCommas(trimmed, maxLength: maxLength)
                chunks.append(contentsOf: parts)
            } else if current.count + trimmed.count + 1 <= maxLength {
                current = current.isEmpty ? trimmed : current + " " + trimmed
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = trimmed
            }
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func splitAtCommas(_ text: String, maxLength: Int) -> [String] {
        let parts = text.components(separatedBy: ", ")
        var chunks: [String] = []
        var current = ""
        for part in parts {
            if current.count + part.count + 2 <= maxLength {
                current = current.isEmpty ? part : current + ", " + part
            } else {
                if !current.isEmpty { chunks.append(current) }
                current = part
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
