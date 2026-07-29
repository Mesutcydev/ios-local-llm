import Foundation
import Combine

// MARK: - SnippetStore
// Quick-insert text templates for the chat composer. Used to save common
// prompts (e.g. "Review this for thread safety:") so the user can fire them
// with one tap. Supports `{cursor}` placeholder for caret position.

@MainActor
final class SnippetStore: ObservableObject {

    static let shared = SnippetStore()

    @Published private(set) var snippets: [PromptSnippet] = []

    private let storageKey = "promptSnippets.v1"

    private init() { load() }

    // MARK: - Built-in starter set (only seeded once, then editable)

    static let starter: [PromptSnippet] = [
        PromptSnippet(title: "Code review",
                      body: "Review this code for bugs, edge cases, and security issues:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Explain code",
                      body: "Explain what this code does line by line:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Refactor",
                      body: "Refactor this for readability and clarity, preserving behaviour:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Add tests",
                      body: "Write unit tests for this function. Cover happy path + edge cases:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Convert to Swift",
                      body: "Convert the following code to idiomatic Swift:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Convert to Python",
                      body: "Convert the following code to idiomatic Python:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Optimise",
                      body: "Identify the algorithmic complexity here and propose a more efficient version:\n\n```\n{cursor}\n```"),
        PromptSnippet(title: "Security audit",
                      body: "Audit this for OWASP issues. Show concrete exploits and patches:\n\n```\n{cursor}\n```"),
    ]

    // MARK: - CRUD

    func add(title: String, body: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTrim = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !bodyTrim.isEmpty else { return }
        snippets.append(PromptSnippet(title: trimmed, body: bodyTrim))
        persist()
    }

    func update(_ snippet: PromptSnippet) {
        if let idx = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[idx] = snippet
            persist()
        }
    }

    func delete(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func resetToStarter() {
        snippets = Self.starter
        persist()
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([PromptSnippet].self, from: data) {
            snippets = decoded
        } else {
            // First launch — seed with starter
            snippets = Self.starter
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

// MARK: - PromptSnippet

struct PromptSnippet: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var body: String

    init(id: UUID = UUID(), title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }

    /// Replaces the `{cursor}` placeholder with empty string; returns
    /// (expandedText, caretPosition).
    func expanded() -> (text: String, caret: Int) {
        if let range = body.range(of: "{cursor}") {
            let pre = body[body.startIndex..<range.lowerBound]
            let post = body[range.upperBound..<body.endIndex]
            return (String(pre) + String(post), pre.count)
        }
        return (body, body.count)
    }
}
