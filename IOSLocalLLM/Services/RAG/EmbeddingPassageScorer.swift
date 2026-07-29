import Foundation

// MARK: - EmbeddingPassageScorer
//
// Semantic `PassageScorer` — the embedding-based reranker the BM25 fallback
// was always meant to graduate into. Scores each passage by cosine similarity
// of its on-device embedding to the query's. Drop-in compatible with
// `WebPassageReranker` (swap the scorer in its initializer) and reused by the
// Knowledge Base for RAG ranking.
//
// `hybrid` blends in BM25 (lexical) so exact keyword/code-token matches aren't
// lost to pure semantics — the usual win for code and identifier search. The
// two score sets are min-max normalized before blending so neither dominates.

struct EmbeddingPassageScorer: PassageScorer {

    private let embedder: OnDeviceEmbedder
    private let hybrid: Bool
    private let semanticWeight: Double
    private let bm25 = BM25Scorer()

    init(embedder: OnDeviceEmbedder = OnDeviceEmbedder(),
         hybrid: Bool = true,
         semanticWeight: Double = 0.7) {
        self.embedder = embedder
        self.hybrid = hybrid
        self.semanticWeight = min(max(semanticWeight, 0), 1)
    }

    /// True when on-device embeddings exist; callers can decide to fall back
    /// to pure BM25 when this is false.
    var isAvailable: Bool { embedder.isAvailable }

    func score(query: String, passages: [Passage]) -> [Double] {
        guard !passages.isEmpty else { return [] }
        guard embedder.isAvailable, let q = embedder.embed(query) else {
            // No embedding model for this language — defer to lexical scoring.
            return bm25.score(query: query, passages: passages)
        }

        let semantic: [Double] = passages.map { p in
            guard let v = embedder.embed(p.text) else { return 0 }
            return Double(OnDeviceEmbedder.cosine(q, v))
        }

        guard hybrid else { return semantic }

        let lexical = bm25.score(query: query, passages: passages)
        let s = Self.minMax(semantic)
        let l = Self.minMax(lexical)
        return zip(s, l).map { semanticWeight * $0 + (1 - semanticWeight) * $1 }
    }

    private static func minMax(_ xs: [Double]) -> [Double] {
        guard let lo = xs.min(), let hi = xs.max(), hi > lo else {
            return Array(repeating: 0, count: xs.count)
        }
        return xs.map { ($0 - lo) / (hi - lo) }
    }
}
