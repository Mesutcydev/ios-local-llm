import Foundation

struct ApplePCCConversationInput: Equatable, Sendable {
    let instructions: String?
    let prompt: String
}

enum ApplePrivateCloudPromptBuilder {
    /// Converts the app's portable chat history into the text/instructions
    /// split expected by `LanguageModelSession`.
    ///
    /// System turns become session instructions. Visible dialog and hidden
    /// model grounding stay ordered in the prompt. Empty assistant streaming
    /// placeholders are omitted so the final `Assistant:` cue appears once.
    static func build(messages: [ChatMessage]) -> ApplePCCConversationInput {
        let instructions = messages
            .filter { $0.role == .system }
            .map(\.contentForModel)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        let dialog = messages.compactMap { message -> String? in
            guard message.role != .system else { return nil }
            let content = message.contentForModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }

            switch message.role {
            case .user:
                return "User:\n\(content)"
            case .assistant:
                return "Assistant:\n\(content)"
            case .tool:
                return "Tool result:\n\(content)"
            case .system:
                return nil
            }
        }

        let promptBody = dialog.joined(separator: "\n\n")
        let prompt = promptBody.isEmpty
            ? "User:\nPlease respond to the provided instructions.\n\nAssistant:"
            : "\(promptBody)\n\nAssistant:"

        return ApplePCCConversationInput(
            instructions: instructions.isEmpty ? nil : instructions,
            prompt: prompt
        )
    }
}
