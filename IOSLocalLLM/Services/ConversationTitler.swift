import Foundation

// MARK: - ConversationTitler
// Uses the active assistant model to produce a short (3-5 word) title for
// a conversation based on its first user message. Runs once per conversation
// after the first reply finishes, so the cost is amortized.
//
// Why not just take the first 40 chars? Because the first message is often
// "Hi" or a long paste of code. The model gives titles that scan well in
// the picker list and capture the actual topic.

@MainActor
enum ConversationTitler {

    /// Generates a title for `firstUserMessage` and writes it to the
    /// conversation in `store`. Skips when the title was already
    /// auto-titled or manually edited. Best-effort — fails silently.
    static func titleIfNeeded(
        conversationID: UUID,
        firstUserMessage: String
    ) async {
        let store = ConversationStore.shared
        let assistant = CodingAssistantService.shared
        guard let conv = store.conversations.first(where: { $0.id == conversationID }) else { return }
        // Only retitle if the existing title is the default or a raw prefix
        // of the user's first message — i.e. we haven't titled it yet.
        let needsTitle =
            conv.title == "New Chat" ||
            firstUserMessage.hasPrefix(conv.title.trimmingCharacters(in: .whitespaces)) ||
            conv.title.hasPrefix(String(firstUserMessage.prefix(40)))
        guard needsTitle else { return }

        // Must have a ready model. Skip silently otherwise so chat keeps
        // working even when the user is offline / model unloaded.
        guard case .ready = assistant.state else { return }

        let prompt = "Summarize the following user request in 3 to 5 words. Lowercase, no punctuation, no quotes. Just the title.\n\nRequest:\n\(firstUserMessage)"
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "You produce ultra-short conversation titles. Output only the title."),
            ChatMessage(role: .user, content: prompt)
        ]

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            final class Acc: @unchecked Sendable { var value = "" }
            let acc = Acc()
            // maxTokensOverride=16 keeps this nano-generate fast without
            // touching AppSettings — avoids clobbering the user's setting if
            // they send a message while the title is being generated.
            assistant.generate(
                messages: messages,
                maxTokensOverride: 16,
                // Titles never need reasoning — and with only 16 tokens a
                // thinking model would spend the entire budget inside an
                // unclosed <think> block, making the title literally "<think>…".
                forceNoThinking: true,
                onToken: { token in acc.value += token },
                onComplete: { _ in
                    Task { @MainActor in
                        let title = cleanTitle(acc.value)
                        guard !title.isEmpty else { cont.resume(); return }
                        // Re-fetch in case the conversation was deleted mid-flight.
                        // ConversationStore.conversations is private(set), so we
                        // round-trip through saveConversation with the existing
                        // messages but the new title applied via setTitle below.
                        store.setTitle(title, for: conversationID)
                        cont.resume()
                    }
                }
            )
        }
    }

    private static func cleanTitle(_ raw: String) -> String {
        var s = raw
        // Drop any reasoning the model emitted. Prefer text AFTER a closing
        // </think>; if the block is unclosed (small token budget), nothing
        // before <think> is usable, so treat as empty (caller keeps the
        // default title, which stays eligible for re-titling).
        if let close = s.range(of: "</think>", options: [.backwards]) {
            s = String(s[close.upperBound...])
        } else if let open = s.range(of: "<think>") {
            s = String(s[..<open.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes and trailing punctuation the model adds.
        s = s.replacingOccurrences(of: "\"", with: "")
             .replacingOccurrences(of: "'", with: "")
             .replacingOccurrences(of: "Title:", with: "", options: .caseInsensitive)
             .trimmingCharacters(in: .whitespaces)
        // Cap word count to 5 in case the model rambles.
        let words = s.split(separator: " ").prefix(5).map(String.init)
        return words.joined(separator: " ").lowercased()
    }
}
