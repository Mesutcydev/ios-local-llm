import Foundation

// MARK: - WebPassageReranker
// BM25-style lexical reranker. The spec called for an on-device embedding
// model; we ship BM25 in v1 to avoid a heavy embedding-model download +
// cold-start cost, and log the choice to WebActivityLogger. The interface
// makes it trivial to swap in an embedder later — just add another type
// that conforms to `PassageScorer` and switch the constructor.

public struct Passage: Sendable, Hashable {
    public let pageIndex: Int     // index into the input pages array
    public let chunkIndex: Int
    public let text: String
    public let approxTokens: Int  // ~ chars / 4

    public init(pageIndex: Int, chunkIndex: Int, text: String, approxTokens: Int) {
        self.pageIndex = pageIndex
        self.chunkIndex = chunkIndex
        self.text = text
        self.approxTokens = approxTokens
    }
}

public protocol PassageScorer: Sendable {
    func score(query: String, passages: [Passage]) -> [Double]
}

public struct WebPassageReranker: Sendable {

    public let scorer: PassageScorer

    public init(scorer: PassageScorer = BM25Scorer()) {
        self.scorer = scorer
    }

    /// Chunk each page into ~400-token windows with 50-token overlap, score
    /// them against `query`, return ordered by score desc.
    public func rerank(query: String, pages: [WebFetchedPage], chunkTokens: Int = 400, overlapTokens: Int = 50) -> [Passage] {
        var passages: [Passage] = []
        let chunkChars = chunkTokens * 4
        let overlapChars = overlapTokens * 4

        for (pageIdx, page) in pages.enumerated() {
            let text = page.extractedText
            guard !text.isEmpty else { continue }
            var cursor = text.startIndex
            var chunk = 0
            while cursor < text.endIndex {
                let end = text.index(cursor, offsetBy: chunkChars, limitedBy: text.endIndex) ?? text.endIndex
                // Snap to last newline / sentence end when possible.
                let snapEnd = Self.snapToSentenceEnd(in: text, range: cursor..<end)
                let raw = String(text[cursor..<snapEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty {
                    let approxTok = max(1, raw.count / 4)
                    passages.append(Passage(pageIndex: pageIdx, chunkIndex: chunk, text: raw, approxTokens: approxTok))
                }
                chunk += 1
                if snapEnd >= text.endIndex { break }
                // Slide forward, leaving overlap.
                let advance = max(snapEnd.utf16Offset(in: text) - overlapChars,
                                  cursor.utf16Offset(in: text) + 1)
                cursor = String.Index(utf16Offset: min(advance, text.utf16.count), in: text)
            }
        }

        guard !passages.isEmpty else { return [] }
        let scores = scorer.score(query: query, passages: passages)
        let indexed = zip(passages, scores).map { ($0, $1) }
        let sorted = indexed.sorted { $0.1 > $1.1 }
        return sorted.map { $0.0 }
    }

    private static func snapToSentenceEnd(in text: String, range: Range<String.Index>) -> String.Index {
        let candidates: [Character] = [".", "!", "?", "\n"]
        var idx = range.upperBound
        let lowerBound = range.lowerBound
        while idx > lowerBound {
            let prev = text.index(before: idx)
            if candidates.contains(text[prev]) {
                return idx
            }
            idx = prev
        }
        return range.upperBound
    }
}

// MARK: - BM25 scorer

/// Simple BM25 implementation. k1=1.5, b=0.75 — standard values.
public struct BM25Scorer: PassageScorer {
    private let k1: Double
    private let b: Double

    public init(k1: Double = 1.5, b: Double = 0.75) {
        self.k1 = k1
        self.b = b
    }

    public func score(query: String, passages: [Passage]) -> [Double] {
        let queryTerms = Self.tokenize(query)
        guard !queryTerms.isEmpty, !passages.isEmpty else {
            return Array(repeating: 0.0, count: passages.count)
        }

        let docs = passages.map { Self.tokenize($0.text) }
        let avgDocLen = Double(docs.map(\.count).reduce(0, +)) / Double(docs.count)
        let n = Double(docs.count)

        // Document frequency per query term
        var df: [String: Int] = [:]
        for term in Set(queryTerms) {
            df[term] = docs.reduce(0) { $0 + ($1.contains(term) ? 1 : 0) }
        }

        var out = [Double](repeating: 0, count: passages.count)
        for (i, doc) in docs.enumerated() {
            let docLen = Double(doc.count)
            var s = 0.0
            // Term frequencies within this document
            var tf: [String: Int] = [:]
            for tok in doc { tf[tok, default: 0] += 1 }

            for term in Set(queryTerms) {
                guard let n_qi = df[term], n_qi > 0 else { continue }
                let f_qi = Double(tf[term] ?? 0)
                if f_qi == 0 { continue }
                let idf = log((n - Double(n_qi) + 0.5) / (Double(n_qi) + 0.5) + 1)
                let numerator = f_qi * (k1 + 1)
                let denominator = f_qi + k1 * (1 - b + b * docLen / max(avgDocLen, 1))
                s += idf * (numerator / denominator)
            }
            out[i] = s
        }
        return out
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 1 }
    }
}
