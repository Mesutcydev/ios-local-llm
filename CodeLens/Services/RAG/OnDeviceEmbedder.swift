import Foundation
import NaturalLanguage

// MARK: - OnDeviceEmbedder
//
// Zero-download, fully on-device text embeddings via Apple's NaturalLanguage
// framework. This is the embedder the WebPassageReranker comment always
// wanted ("swap in an embedder later") — it powers both semantic web reranking
// and the Knowledge Base (RAG over the user's own files), with no model
// download and no network.
//
// Vector-space consistency matters for cosine search: a single embedder
// instance ALWAYS produces vectors in the same space. We prefer sentence
// embeddings; when a chunk is too long for `vector(for:)` to accept (it's
// tuned for sentence-length input), we split it into sentences, embed each in
// the SAME sentence space, and mean-pool — never mixing in word-space vectors.
// Only if sentence embeddings are entirely unavailable for the language do we
// fall back wholesale to word-embedding mean-pooling.
//
// All returned vectors are L2-normalized, so cosine similarity reduces to a
// dot product.

final class OnDeviceEmbedder: @unchecked Sendable {

    /// English by default — the common case for code/docs. A KB pins one
    /// language so its whole index lives in a single vector space.
    let language: NLLanguage
    private let sentence: NLEmbedding?
    private let word: NLEmbedding?

    init(language: NLLanguage = .english) {
        self.language = language
        self.sentence = NLEmbedding.sentenceEmbedding(for: language)
        self.word = NLEmbedding.wordEmbedding(for: language)
    }

    /// True when at least one embedding model exists for the language.
    var isAvailable: Bool { sentence != nil || word != nil }

    /// Dimensionality of the active vector space (sentence preferred).
    var dimension: Int { sentence?.dimension ?? word?.dimension ?? 0 }

    /// Embed `text` into an L2-normalized vector, or nil if no model applies.
    func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let sentence {
            // Direct path — works for sentence-length input.
            if let v = sentence.vector(for: trimmed) {
                return Self.normalize(v)
            }
            // Long input: mean-pool per-sentence vectors in the SAME space.
            let sentences = Self.splitSentences(trimmed)
            var acc = [Double](repeating: 0, count: sentence.dimension)
            var n = 0
            for s in sentences {
                if let v = sentence.vector(for: s) {
                    for i in 0..<acc.count { acc[i] += v[i] }
                    n += 1
                }
            }
            if n > 0 {
                return Self.normalize(acc.map { $0 / Double(n) })
            }
            // Fall through to word-space only if sentence space produced nothing.
        }

        guard let word else { return nil }
        let tokens = Self.tokenizeWords(trimmed)
        guard !tokens.isEmpty else { return nil }
        var acc = [Double](repeating: 0, count: word.dimension)
        var n = 0
        for t in tokens {
            if let v = word.vector(for: t) {
                for i in 0..<acc.count { acc[i] += v[i] }
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return Self.normalize(acc.map { $0 / Double(n) })
    }

    /// Cosine similarity of two L2-normalized vectors (== dot product).
    /// Returns 0 on dimension mismatch (defensive — shouldn't happen within
    /// one embedder/index).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }

    // MARK: - Helpers

    private static func normalize(_ v: [Double]) -> [Float] {
        var norm = 0.0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return v.map { Float($0) } }
        return v.map { Float($0 / norm) }
    }

    private static func splitSentences(_ text: String) -> [String] {
        let tk = NLTokenizer(unit: .sentence)
        tk.string = text
        var out: [String] = []
        tk.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [text] : out
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        let tk = NLTokenizer(unit: .word)
        tk.string = text
        var out: [String] = []
        tk.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let w = String(text[range]).lowercased()
            if w.count > 1 { out.append(w) }
            return true
        }
        return out
    }
}
