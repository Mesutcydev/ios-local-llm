import Foundation
import Combine

// MARK: - MemoryStore
// Persistent "remember this about me" facts that get injected into the system
// prompt for every conversation. Modelled after ChatGPT Memory / Claude
// Projects' instruction blocks.
//
// Stored as a JSON array of dated facts in UserDefaults (tiny payload).
// User adds/removes/edits via Settings → Memory.

@MainActor
final class MemoryStore: ObservableObject {

    static let shared = MemoryStore()

    @Published private(set) var facts: [MemoryFact] = []

    private let storageKey = "memoryFacts.v1"

    struct MemoryFact: Identifiable, Codable, Hashable {
        var id: UUID
        var text: String
        var createdAt: Date
        /// Optional persona scope. nil = global fact (every persona sees it);
        /// a persona id = only that persona's conversations include it.
        var personaID: String?

        init(text: String, personaID: String? = nil) {
            self.id = UUID()
            self.text = text
            self.createdAt = .now
            self.personaID = personaID
        }
    }

    private init() {
        load()
    }

    // MARK: - Public API

    func add(_ text: String, personaID: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        facts.append(MemoryFact(text: trimmed, personaID: personaID))
        persist()
    }

    func update(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = facts.firstIndex(where: { $0.id == id }) {
            facts[idx].text = trimmed
            persist()
        }
    }

    func delete(id: UUID) {
        facts.removeAll { $0.id == id }
        persist()
    }

    func clearAll() {
        facts.removeAll()
        persist()
    }

    /// Returns the system-prompt block that gets appended whenever the user
    /// has at least one memory. Empty when no facts.
    var contextBlock: String {
        contextBlock(forPersonaID: nil)
    }

    /// Scoped context: includes globals (personaID == nil) plus any facts
    /// pinned to the active persona id.
    func contextBlock(forPersonaID personaID: String?) -> String {
        let scoped = facts.filter { $0.personaID == nil || $0.personaID == personaID }
        guard !scoped.isEmpty else { return "" }
        let bullets = scoped.map { "- \($0.text)" }.joined(separator: "\n")
        return """
        Important things to remember about the user across all conversations:
        \(bullets)
        Use this context naturally without restating it. Don't mention that you
        "remember" anything; just apply the information.
        """
    }

    /// Number of facts in scope for a given persona — used for the
    /// in-conversation "memory used" chip.
    func countInScope(forPersonaID personaID: String?) -> Int {
        facts.filter { $0.personaID == nil || $0.personaID == personaID }.count
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MemoryFact].self, from: data)
        else { return }
        facts = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(facts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
