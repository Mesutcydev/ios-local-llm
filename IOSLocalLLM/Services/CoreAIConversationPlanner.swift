import Foundation

/// Turns an OpenAI-style chat history into the pieces Core AI needs:
/// system instructions, prior transcript turns, and the latest user prompt.
///
/// `LanguageModelSession.streamResponse(to:)` applies the model's chat
/// template to one user turn. Flattening the whole thread into
/// `"user: …\\nassistant: …"` made every prior turn look like a single user
/// message, so the tokenizer wrapped it again.
enum CoreAIConversationPlanner {
    private static let truncationMarker = "\n[…content shortened to fit this Core AI model…]\n"

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

    /// Rewrites only the runtime snapshot, never the stored conversation.
    /// The shared Assistant prompt contains a detailed tool manual designed
    /// for large MLX/GGUF windows. Sending that unchanged through Core AI's
    /// verified 1K state consumed almost the entire prompt allowance and made
    /// ordinary follow-ups look stateless.
    static func applyingCompactPromptPolicy(
        to messages: [ChatMessage],
        toolsEnabled: Bool
    ) -> [ChatMessage] {
        var result = messages
        var addedRuntimeAddendum = false

        for index in result.indices where result[index].role == .system {
            var text = result[index].contentForModel
            text = ToolRunner.removingSystemPromptAddendum(from: text)
            text = text.replacingOccurrences(
                of: CodingAssistantService.groundingPrompt,
                with: CodingAssistantService.compactGroundingPrompt
            )
            text = text.replacingOccurrences(
                of: CodingAssistantService.responseFormattingPrompt,
                with: ""
            )
            if !addedRuntimeAddendum {
                text += toolsEnabled
                    ? ToolRunner.coreAISystemPromptAddendum
                    : ToolRunner.unavailablePromptAddendum
                addedRuntimeAddendum = true
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if result[index].modelContent != nil {
                result[index].modelContent = text
            } else {
                result[index].content = text
            }
        }

        if !addedRuntimeAddendum {
            result.insert(
                ChatMessage(
                    role: .system,
                    content: toolsEnabled
                        ? ToolRunner.coreAISystemPromptAddendum
                        : ToolRunner.unavailablePromptAddendum
                ),
                at: 0
            )
        }
        return result
    }

    /// Applies the shared conversation-retention policy, then enforces the
    /// small Core AI runtime's hard input boundary. The shared trimmer keeps
    /// the newest user turn intact by design; that is appropriate for large
    /// MLX/GGUF windows, but a single attached document can be many times
    /// larger than Core AI's verified 1K sequence length. Keep both ends so
    /// file metadata/opening context and the user's trailing question survive.
    static func boundedRuntimeMessages(
        _ messages: [ChatMessage],
        maxTokens: Int
    ) -> [ChatMessage] {
        guard maxTokens > 8 else { return [] }

        let originalSystemMessages = messages.filter { $0.role == .system }
        let originalSystem = originalSystemMessages
            .map(\.contentForModel)
            .joined(separator: "\n\n")
        let systemTokenCap = min(maxTokens / 2, maxTokens - 8)
        let boundedSystem: [ChatMessage]
        if estimatedTokens(in: originalSystemMessages) <= systemTokenCap {
            boundedSystem = originalSystemMessages
        } else {
            let boundedSystemText = clipped(
                originalSystem,
                characterLimit: max(0, systemTokenCap - 4) * 4
            )
            boundedSystem = boundedSystemText.isEmpty
                ? []
                : [ChatMessage(role: .system, content: boundedSystemText)]
        }

        let dialog = messages.filter { $0.role != .system }
        let candidates = boundedSystem + dialog
        let normallyTrimmed = CodingAssistantService.trimToInputBudget(
            candidates,
            maxTokens: maxTokens
        )
        if estimatedRuntimeTokens(in: normallyTrimmed) <= maxTokens {
            return normallyTrimmed
        }

        guard let latest = dialog.last else { return boundedSystem }
        let systemCost = estimatedTokens(in: boundedSystem)
        let latestBudget = max(4, maxTokens - systemCost)
        var boundedLatest = latest
        // Attached/code payloads tokenize more densely than prose. The shared
        // 4-characters-per-token estimate is useful for large runtimes but is
        // not a safe hard boundary for Core AI, so reserve at 2 chars/token
        // for hidden grounding and 3 for ordinary pasted text.
        let charactersPerToken = latest.modelContent == nil ? 3 : 2
        let boundedLatestText = clipped(
            latest.contentForModel,
            characterLimit: max(0, latestBudget - 4) * charactersPerToken
        )
        if boundedLatest.modelContent != nil {
            boundedLatest.modelContent = boundedLatestText
        } else {
            boundedLatest.content = boundedLatestText
        }
        return boundedSystem + [boundedLatest]
    }

    static func estimatedTokens(in messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + $1.contentForModel.count / 4 + 4 }
    }

    static func estimatedRuntimeTokens(in messages: [ChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            let divisor: Int
            if message.role == .system {
                divisor = 4
            } else {
                divisor = message.modelContent == nil ? 3 : 2
            }
            return total + message.contentForModel.count / divisor + 4
        }
    }

    private static func clipped(_ text: String, characterLimit: Int) -> String {
        guard characterLimit > 0 else { return "" }
        guard text.count > characterLimit else { return text }
        guard characterLimit > truncationMarker.count else {
            return String(text.suffix(characterLimit))
        }

        let available = characterLimit - truncationMarker.count
        let tailCount = max(1, available / 3)
        let headCount = available - tailCount
        return String(text.prefix(headCount))
            + truncationMarker
            + String(text.suffix(tailCount))
    }

    static func plan(messages: [ChatMessage]) -> Plan? {
        let system = messages
            .filter { $0.role == .system }
            .map(\.contentForModel)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A tool result is intentionally stored as a user message by the
        // shared Assistant UI. When it is the trailing turn, it must become
        // the prompt for the follow-up generation; excluding it here made
        // Core AI run a second pass without ever seeing the tool output.
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
                if let tool = toolTurn(from: message) {
                    history.append(tool)
                    continue
                }
                guard !text.isEmpty else { continue }
                history.append(.user(text))
            case .assistant:
                guard !text.isEmpty else { continue }
                history.append(.assistant(text))
            case .tool:
                history.append(toolTurn(from: message) ?? .tool(
                    id: message.id.uuidString,
                    name: "tool",
                    content: text
                ))
            }
        }
        return Plan(system: system, history: history, latestUser: latestUser)
    }

    /// The workbench stores some tool results as `.user` turns (fenced
    /// `tool_result` blocks or Local API `[Tool result for call_id=…]`
    /// prefixes). Treat those as transcript tool output, not extra user
    /// prompts.
    static func looksLikeToolResult(_ message: ChatMessage) -> Bool {
        if message.role == .tool { return true }
        let text = message.contentForModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("```tool_result")
            || text.hasPrefix("[Tool result for call_id=")
            || text.hasPrefix("TOOL RESULT:")
    }

    static func toolTurn(from message: ChatMessage) -> Turn? {
        guard looksLikeToolResult(message) else { return nil }
        let parsed = toolIdentity(from: message)
        return .tool(id: parsed.id, name: parsed.name, content: parsed.content)
    }

    static func toolIdentity(from message: ChatMessage) -> (id: String, name: String, content: String) {
        let text = message.contentForModel
        var id = message.id.uuidString
        var name = "tool"

        if let marker = text.range(of: "[Tool result for call_id="),
           let end = text[marker.upperBound...].firstIndex(of: "]") {
            let parsed = String(text[marker.upperBound..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !parsed.isEmpty { id = parsed }
        }

        if text.hasPrefix("TOOL RESULT:") {
            let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            let parsed = line
                .replacingOccurrences(of: "TOOL RESULT:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !parsed.isEmpty { name = parsed }
        }

        if let json = firstJSONObject(in: text) {
            if let parsedName = json["name"] as? String, !parsedName.isEmpty {
                name = parsedName
            }
            if let parsedID = json["id"] as? String, !parsedID.isEmpty {
                id = parsedID
            } else if let parsedID = json["tool_call_id"] as? String, !parsedID.isEmpty {
                id = parsedID
            }
        }

        return (id, name, text)
    }

    private static func firstJSONObject(in text: String) -> [String: Any]? {
        let bytes = Array(text.utf8)
        var start: Int?
        var depth = 0
        var inString = false
        var escaped = false
        for (index, byte) in bytes.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B {
                if depth == 0 { start = index }
                depth += 1
            } else if byte == 0x7D, depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    let data = Data(bytes[start...index])
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return object
                    }
                }
            }
        }
        return nil
    }
}
