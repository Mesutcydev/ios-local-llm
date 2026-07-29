import Foundation
import Combine

// MARK: - KnowledgeBaseService
//
// On-device RAG over the user's own files / pasted text. Index a document and
// it's chunked, embedded with `OnDeviceEmbedder` (no download, no network),
// and persisted to Application Support. At ask-time the assistant retrieves the
// most relevant chunks by cosine similarity and injects them as grounding
// context — "chat with your documents/codebase, fully offline."
//
// Everything stays on device: vectors live in a local JSON index, never
// uploaded. This is the flagship differentiator — no competitor offers private
// on-device RAG.

struct KBDocument: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var addedAt: Date
    var chunkCount: Int
    var byteCount: Int
}

struct KBChunk: Codable {
    let id: UUID
    let docID: UUID
    let text: String
    let vector: [Float]
}

/// A retrieved chunk with its similarity score and originating document name.
struct KBRetrieval: Identifiable {
    let id: UUID
    let docName: String
    let text: String
    let score: Float
}

@MainActor
final class KnowledgeBaseService: ObservableObject {

    static let shared = KnowledgeBaseService()

    @Published private(set) var documents: [KBDocument] = []
    @Published private(set) var isIndexing = false
    /// When true the assistant augments answers with retrieved KB context.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private var chunks: [KBChunk] = []
    private let embedder = OnDeviceEmbedder()

    private static let enabledKey = "knowledgeBase.enabled"

    /// Guardrails so a giant paste can't OOM the embedder or balloon the index.
    private let maxCharsPerDoc = 600_000          // ~150k tokens of source
    private let chunkChars = 1_600                // ~400 tokens
    private let overlapChars = 200                // ~50 tokens
    private let maxChunksPerDoc = 400
    private let maxTotalChunks = 5_000

    /// True when on-device embeddings are usable (language model present).
    var isAvailable: Bool { embedder.isAvailable }
    var totalChunks: Int { chunks.count }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        load()
    }

    // MARK: - Mutation

    /// Chunk + embed `text` and add it as a document named `name`. Embedding
    /// runs off the main actor; the index is updated and persisted on return.
    func addDocument(name: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, embedder.isAvailable else {
            if !embedder.isAvailable {
                ToastCenter.shared.error("Knowledge Base unavailable",
                                         detail: "On-device embeddings aren't supported for this language.")
            }
            return
        }
        if chunks.count >= maxTotalChunks {
            ToastCenter.shared.error("Knowledge Base full",
                                     detail: "Remove older documents before indexing more.")
            return
        }
        let clipped = String(trimmed.prefix(maxCharsPerDoc))
        isIndexing = true
        defer { isIndexing = false }

        let docID = UUID()
        let embedder = self.embedder
        let chunkChars = self.chunkChars
        let overlapChars = self.overlapChars
        let maxChunks = self.maxChunksPerDoc

        let newChunks: [KBChunk] = await Task.detached(priority: .userInitiated) {
            let windows = Self.chunk(clipped, chunkChars: chunkChars,
                                     overlapChars: overlapChars, maxChunks: maxChunks)
            var out: [KBChunk] = []
            out.reserveCapacity(windows.count)
            for w in windows {
                guard let v = embedder.embed(w) else { continue }
                out.append(KBChunk(id: UUID(), docID: docID, text: w, vector: v))
            }
            return out
        }.value

        guard !newChunks.isEmpty else {
            ToastCenter.shared.error("Couldn't index \(name)", detail: "No embeddable text found.")
            return
        }

        chunks.append(contentsOf: newChunks)
        documents.append(KBDocument(id: docID, name: name, addedAt: Date(),
                                    chunkCount: newChunks.count, byteCount: clipped.utf8.count))
        persist()
        HapticManager.impact(.medium)
        ToastCenter.shared.success("Added to Knowledge Base",
                                   detail: "\(name) · \(newChunks.count) chunks")
    }

    func removeDocument(_ id: UUID) {
        documents.removeAll { $0.id == id }
        chunks.removeAll { $0.docID == id }
        persist()
    }

    func clear() {
        documents.removeAll()
        chunks.removeAll()
        persist()
    }

    // MARK: - Retrieval

    /// Top-`k` chunks most similar to `query` (cosine), above `minScore`.
    func retrieve(query: String, topK: Int = 5, minScore: Float = 0.15) -> [KBRetrieval] {
        guard !chunks.isEmpty, let q = embedder.embed(query) else { return [] }
        let scored: [(KBChunk, Float)] = chunks.map { ($0, OnDeviceEmbedder.cosine(q, $0.vector)) }
        let docNames = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.name) })
        return scored
            .filter { $0.1 >= minScore }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { KBRetrieval(id: $0.0.id, docName: docNames[$0.0.docID] ?? "document", text: $0.0.text, score: $0.1) }
    }

    /// Rendered grounding block for the assistant prompt, or nil when the KB
    /// is empty/disabled or nothing relevant is found. Honors an approximate
    /// token budget (chars/4).
    func contextBlock(for query: String, tokenBudget: Int = 1_200) -> (block: String, sources: [String])? {
        guard isEnabled, !chunks.isEmpty else { return nil }
        let hits = retrieve(query: query, topK: 6)
        guard !hits.isEmpty else { return nil }

        var lines: [String] = [
            "KNOWLEDGE BASE CONTEXT — excerpts from the user's own files. Use them to answer and cite the [source] when you do. If they don't contain the answer, say so.",
            ""
        ]
        var usedChars = lines.joined().count
        let budgetChars = tokenBudget * 4
        var sources: [String] = []
        for h in hits {
            let entry = "[\(h.docName)]\n\(h.text)\n"
            if usedChars + entry.count > budgetChars { break }
            lines.append(entry)
            usedChars += entry.count
            if !sources.contains(h.docName) { sources.append(h.docName) }
        }
        lines.append("KNOWLEDGE BASE END")
        guard sources.count > 0 else { return nil }
        return (lines.joined(separator: "\n"), sources)
    }

    // MARK: - Chunking

    nonisolated static func chunk(_ text: String, chunkChars: Int, overlapChars: Int, maxChunks: Int) -> [String] {
        var out: [String] = []
        var cursor = text.startIndex
        while cursor < text.endIndex && out.count < maxChunks {
            let end = text.index(cursor, offsetBy: chunkChars, limitedBy: text.endIndex) ?? text.endIndex
            let snapEnd = snapToBoundary(in: text, range: cursor..<end)
            let raw = String(text[cursor..<snapEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { out.append(raw) }
            if snapEnd >= text.endIndex { break }
            let advance = max(snapEnd.utf16Offset(in: text) - overlapChars,
                              cursor.utf16Offset(in: text) + 1)
            cursor = String.Index(utf16Offset: min(advance, text.utf16.count), in: text)
        }
        return out
    }

    nonisolated private static func snapToBoundary(in text: String, range: Range<String.Index>) -> String.Index {
        let candidates: Set<Character> = [".", "!", "?", "\n"]
        var idx = range.upperBound
        let lower = range.lowerBound
        while idx > lower {
            let prev = text.index(before: idx)
            if candidates.contains(text[prev]) { return idx }
            idx = prev
        }
        return range.upperBound
    }

    // MARK: - Persistence

    private struct Index: Codable { var documents: [KBDocument]; var chunks: [KBChunk] }

    private static var indexURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.json")
    }

    private func persist() {
        let index = Index(documents: documents, chunks: chunks)
        do {
            let data = try JSONEncoder().encode(index)
            try data.write(to: Self.indexURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            // Non-fatal: the in-memory index still works this session.
            print("[KnowledgeBase] persist failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        documents = index.documents
        chunks = index.chunks
    }
}
