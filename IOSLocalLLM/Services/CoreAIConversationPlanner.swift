import Foundation

/// Turns an OpenAI-style chat history into the pieces Core AI needs:
/// system instructions, prior transcript turns, and the latest user prompt.
///
/// `LanguageModelSession.streamResponse(to:)` applies the model's chat
/// template to one user turn. Flattening the whole thread into
/// `"user: …\\nassistant: …"` made every prior turn look like a single user
/// message, so the tokenizer wrapped it again.
enum CoreAIConversationPlanner {
    enum Turn: Equatable, Sendable {
        case user(String)
        case assistant(String)
        case tool(id: String, name: String, content: String)
    }

    struct Plan: Equatable, Sendable {
        var system: String
        var history: [Turn]
        var latestUser: String
    }

    static func plan(messages: [ChatMessage]) -> Plan? {
        let system = messages
            .filter { $0.role == .system }
            .map(\.contentForModel)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let latestUser = messages[lastUserIndex].contentForModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latestUser.isEmpty else { return nil }

        var history: [Turn] = []
        history.reserveCapacity(lastUserIndex)
        for message in messages[..<lastUserIndex] {
            let text = message.contentForModel
            switch message.role {
            case .system:
                continue
            case .user:
                guard !text.isEmpty else { continue }
                history.append(.user(text))
            case .assistant:
                guard !text.isEmpty else { continue }
                history.append(.assistant(text))
            case .tool:
                history.append(.tool(
                    id: message.toolCallID ?? message.id.uuidString,
                    name: message.toolCalls?.first?.name ?? "tool",
                    content: text
                ))
            }
        }
        return Plan(system: system, history: history, latestUser: latestUser)
    }
}
