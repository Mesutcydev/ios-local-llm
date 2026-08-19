import CryptoKit
import Darwin
import Foundation
import Network
import UIKit

enum LocalAPIValidation {
    static let portRange = 1024...65535

    static func validPort(_ value: Int) -> UInt16? {
        guard portRange.contains(value) else { return nil }
        return UInt16(value)
    }

    static func modelMatches(_ requested: String, id: String, repoID: String) -> Bool {
        requested == id || requested == repoID
    }

    static func isReachableLANInterface(_ name: String) -> Bool {
        let excludedPrefixes = ["lo", "utun", "ipsec", "awdl", "llw", "pdp_ip"]
        return !excludedPrefixes.contains(where: name.hasPrefix)
    }

    /// Approved browser origins parsed from the comma-separated settings
    /// value. Empty list means CORS stays off — the API serves terminal
    /// clients, and a wildcard would let any web page on the LAN read
    /// responses.
    static func corsAllowedOrigins(settingValue: String) -> [String] {
        settingValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Reflects the request origin only when it appears in the approved
    /// list. Returns nil for absent (terminal clients), empty, or
    /// unapproved origins — the response then carries no CORS headers and
    /// browsers block cross-origin reads.
    static func allowedCORSOrigin(origin: String?, settingValue: String) -> String? {
        guard let origin,
              !origin.isEmpty,
              corsAllowedOrigins(settingValue: settingValue).contains(origin) else {
            return nil
        }
        return origin
    }
}

enum LocalAPIKeyStore {
    static let account = "localAPI.bearerKey"

    static func key() -> String {
        if let existing = KeychainStore.get(account: account), !existing.isEmpty {
            return existing
        }
        return rotate()
    }

    @discardableResult
    static func rotate() -> String {
        let value = "odl_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        KeychainStore.set(value, account: account)
        return value
    }
}

enum LocalAPIProtocolError: Error, Equatable {
    case malformed(String)
    case unsupported(String)
    case unknownModel
}

struct LocalAPIToolDefinition: Equatable, Sendable {
    let name: String
    let description: String?
    let parametersJSON: String
}

enum LocalAPIToolChoice: Equatable, Sendable {
    case auto
    case none
    case required
    case function(String)
}

struct LocalAPIToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
}

struct LocalAPIChatRequest {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let tools: [LocalAPIToolDefinition]
    let toolChoice: LocalAPIToolChoice
    let parallelToolCalls: Bool

    static func decodeOpenAI(_ data: Data) throws -> Self {
        let raw = try object(data)
        let tools = try decodeOpenAITools(raw["tools"])
        let toolChoice = try decodeOpenAIToolChoice(raw["tool_choice"], tools: tools)
        try reject(
            raw,
            keys: ["functions"],
            message: "This request uses an option that the text-chat API does not support."
        )
        guard let model = raw["model"] as? String, !model.isEmpty,
              let rows = raw["messages"] as? [[String: Any]], !rows.isEmpty else {
            throw LocalAPIProtocolError.malformed("model and messages are required")
        }
        return Self(
            model: model,
            messages: try decodeMessages(rows),
            stream: raw["stream"] as? Bool ?? false,
            maxTokens: integer(raw["max_completion_tokens"] ?? raw["max_tokens"]),
            temperature: number(raw["temperature"]),
            topP: number(raw["top_p"]),
            tools: tools,
            toolChoice: toolChoice,
            parallelToolCalls: raw["parallel_tool_calls"] as? Bool ?? true
        )
    }

    static func decodeOpenAIResponses(_ data: Data) throws -> Self {
        let raw = try object(data)
        try rejectNonEmptyTools(raw)
        try reject(
            raw,
            keys: [
                "tool_choice", "parallel_tool_calls", "text", "reasoning",
                "truncation", "include", "previous_response_id", "store",
                "metadata", "service_tier"
            ],
            message: "This request uses an option that the Responses API compatibility layer does not support."
        )
        guard let model = raw["model"] as? String, !model.isEmpty,
              raw["input"] != nil else {
            throw LocalAPIProtocolError.malformed("model and input are required")
        }

        var messages: [ChatMessage] = []
        if let instructions = raw["instructions"] as? String, !instructions.isEmpty {
            messages.append(ChatMessage(role: .system, content: instructions))
        }
        if let input = raw["input"] as? String {
            messages.append(ChatMessage(role: .user, content: input))
        } else if let rows = raw["input"] as? [[String: Any]], !rows.isEmpty {
            messages.append(contentsOf: try decodeResponseInput(rows))
        } else {
            throw LocalAPIProtocolError.unsupported(
                "input must be a string or a non-empty array of text messages."
            )
        }
        return Self(
            model: model,
            messages: messages,
            stream: raw["stream"] as? Bool ?? false,
            maxTokens: integer(raw["max_output_tokens"]),
            temperature: number(raw["temperature"]),
            topP: number(raw["top_p"]),
            tools: [],
            toolChoice: .none,
            parallelToolCalls: false
        )
    }

    static func decodeOllamaChat(_ data: Data) throws -> Self {
        let raw = try object(data)
        try reject(
            raw,
            keys: ["format", "think", "keep_alive", "logprobs", "top_logprobs"],
            message: "This request uses an Ollama option that is not supported."
        )
        guard let rows = raw["messages"] as? [[String: Any]], !rows.isEmpty else {
            throw LocalAPIProtocolError.malformed("messages are required")
        }
        let model = raw["model"] as? String ?? ""
        let options = raw["options"] as? [String: Any] ?? [:]
        let tools = try decodeOpenAITools(raw["tools"])
        return Self(
            model: model,
            messages: try decodeMessages(rows),
            stream: raw["stream"] as? Bool ?? true,
            maxTokens: integer(options["num_predict"]),
            temperature: number(options["temperature"]),
            topP: number(options["top_p"]),
            tools: tools,
            toolChoice: tools.isEmpty ? .none : .auto,
            parallelToolCalls: false
        )
    }

    static func decodeOllamaGenerate(_ data: Data) throws -> Self {
        let raw = try object(data)
        try reject(
            raw,
            keys: ["images", "format", "suffix", "think", "raw", "keep_alive", "logprobs", "top_logprobs"],
            message: "This request uses an Ollama option that is not supported."
        )
        guard let model = raw["model"] as? String, !model.isEmpty,
              let prompt = raw["prompt"] as? String else {
            throw LocalAPIProtocolError.malformed("model and prompt are required")
        }
        let options = raw["options"] as? [String: Any] ?? [:]
        var messages: [ChatMessage] = []
        if let system = raw["system"] as? String, !system.isEmpty {
            messages.append(ChatMessage(role: .system, content: system))
        }
        messages.append(ChatMessage(role: .user, content: prompt))
        return Self(
            model: model,
            messages: messages,
            stream: raw["stream"] as? Bool ?? true,
            maxTokens: integer(options["num_predict"]),
            temperature: number(options["temperature"]),
            topP: number(options["top_p"]),
            tools: [],
            toolChoice: .none,
            parallelToolCalls: false
        )
    }

    static func decodeAnthropic(_ data: Data) throws -> Self {
        let raw = try object(data)
        try reject(
            raw,
            keys: [
                "metadata", "stop_sequences",
                "thinking", "mcp_servers", "service_tier"
            ],
            message: "This request uses an Anthropic option that the text-only API does not support."
        )
        guard let model = raw["model"] as? String, !model.isEmpty,
              let rows = raw["messages"] as? [[String: Any]], !rows.isEmpty,
              let maxTokens = integer(raw["max_tokens"]) else {
            throw LocalAPIProtocolError.malformed("model, messages, and max_tokens are required")
        }
        let tools = try decodeAnthropicTools(raw["tools"])
        let toolChoice = try decodeAnthropicToolChoice(raw["tool_choice"], tools: tools)
        var messages: [ChatMessage] = []
        if let system = try decodeAnthropicContent(raw["system"]), !system.isEmpty {
            messages.append(ChatMessage(role: .system, content: system))
        }
        messages.append(contentsOf: try rows.map { row in
            guard let roleString = row["role"] as? String,
                  let content = try decodeAnthropicMessageContent(row["content"]),
                  !content.isEmpty else {
                throw LocalAPIProtocolError.unsupported(
                    "Anthropic messages must contain text, tool_use, or tool_result blocks."
                )
            }
            switch roleString {
            case "user": return ChatMessage(role: .user, content: content)
            case "assistant": return ChatMessage(role: .assistant, content: content)
            default:
                throw LocalAPIProtocolError.unsupported("Message role '\(roleString)' is not supported.")
            }
        })
        return Self(
            model: model,
            messages: messages,
            stream: raw["stream"] as? Bool ?? false,
            maxTokens: maxTokens,
            temperature: number(raw["temperature"]),
            topP: number(raw["top_p"]),
            tools: tools,
            toolChoice: toolChoice,
            parallelToolCalls: false
        )
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else {
            throw LocalAPIProtocolError.malformed("request body must be a JSON object")
        }
        return object
    }

    private static func reject(_ raw: [String: Any], keys: [String], message: String) throws {
        if keys.contains(where: { raw[$0] != nil }) {
            throw LocalAPIProtocolError.unsupported(message)
        }
    }

    private static func rejectNonEmptyTools(_ raw: [String: Any]) throws {
        guard let value = raw["tools"] else { return }
        guard let tools = value as? [Any] else {
            throw LocalAPIProtocolError.malformed("tools must be an array")
        }
        if !tools.isEmpty {
            throw LocalAPIProtocolError.unsupported(
                "Tool calling is not supported by this compatibility endpoint."
            )
        }
    }

    private static func decodeOpenAITools(_ value: Any?) throws -> [LocalAPIToolDefinition] {
        guard let value else { return [] }
        guard let rows = value as? [[String: Any]] else {
            throw LocalAPIProtocolError.malformed("tools must be an array")
        }
        return try rows.map { row in
            guard row["type"] as? String == "function",
                  let function = row["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty else {
                throw LocalAPIProtocolError.malformed(
                    "Each tool must be a named function."
                )
            }
            let parameters = function["parameters"] ?? [
                "type": "object",
                "properties": [:]
            ]
            guard JSONSerialization.isValidJSONObject(parameters),
                  let data = try? JSONSerialization.data(
                    withJSONObject: parameters,
                    options: [.sortedKeys]
                  ),
                  let parametersJSON = String(data: data, encoding: .utf8) else {
                throw LocalAPIProtocolError.malformed(
                    "Tool '\(name)' has an invalid parameters schema."
                )
            }
            return LocalAPIToolDefinition(
                name: name,
                description: function["description"] as? String,
                parametersJSON: parametersJSON
            )
        }
    }

    private static func decodeAnthropicTools(_ value: Any?) throws -> [LocalAPIToolDefinition] {
        guard let value else { return [] }
        guard let rows = value as? [[String: Any]] else {
            throw LocalAPIProtocolError.malformed("tools must be an array")
        }
        return try rows.map { row in
            guard let name = row["name"] as? String, !name.isEmpty else {
                throw LocalAPIProtocolError.malformed(
                    "Each Anthropic tool must have a name."
                )
            }
            let schema = row["input_schema"] ?? [
                "type": "object",
                "properties": [:]
            ]
            guard JSONSerialization.isValidJSONObject(schema),
                  let data = try? JSONSerialization.data(
                    withJSONObject: schema,
                    options: [.sortedKeys]
                  ),
                  let parametersJSON = String(data: data, encoding: .utf8) else {
                throw LocalAPIProtocolError.malformed(
                    "Tool '\(name)' has an invalid input_schema."
                )
            }
            return LocalAPIToolDefinition(
                name: name,
                description: row["description"] as? String,
                parametersJSON: parametersJSON
            )
        }
    }

    private static func decodeAnthropicToolChoice(
        _ value: Any?,
        tools: [LocalAPIToolDefinition]
    ) throws -> LocalAPIToolChoice {
        guard let value else { return tools.isEmpty ? .none : .auto }
        guard let object = value as? [String: Any],
              let type = object["type"] as? String else {
            throw LocalAPIProtocolError.malformed(
                "Anthropic tool_choice must be an object."
            )
        }
        let choice: LocalAPIToolChoice
        switch type {
        case "auto": choice = .auto
        case "none": choice = .none
        case "any": choice = .required
        case "tool":
            guard let name = object["name"] as? String, !name.isEmpty else {
                throw LocalAPIProtocolError.malformed(
                    "A tool tool_choice requires a name."
                )
            }
            choice = .function(name)
        default:
            throw LocalAPIProtocolError.malformed(
                "Unsupported Anthropic tool_choice type '\(type)'."
            )
        }
        if case .function(let name) = choice,
           !tools.contains(where: { $0.name == name }) {
            throw LocalAPIProtocolError.malformed(
                "tool_choice references unknown tool '\(name)'."
            )
        }
        if tools.isEmpty, choice != .none {
            throw LocalAPIProtocolError.malformed(
                "tool_choice requires at least one tool."
            )
        }
        return choice
    }

    private static func decodeOpenAIToolChoice(
        _ value: Any?,
        tools: [LocalAPIToolDefinition]
    ) throws -> LocalAPIToolChoice {
        guard let value else { return tools.isEmpty ? .none : .auto }
        let choice: LocalAPIToolChoice
        if let string = value as? String {
            switch string {
            case "auto": choice = .auto
            case "none": choice = .none
            case "required": choice = .required
            default:
                throw LocalAPIProtocolError.malformed(
                    "tool_choice must be auto, none, required, or a named function."
                )
            }
        } else if let object = value as? [String: Any],
                  object["type"] as? String == "function",
                  let function = object["function"] as? [String: Any],
                  let name = function["name"] as? String,
                  !name.isEmpty {
            choice = .function(name)
        } else {
            throw LocalAPIProtocolError.malformed(
                "tool_choice must be auto, none, required, or a named function."
            )
        }

        switch choice {
        case .auto where tools.isEmpty, .required where tools.isEmpty:
            throw LocalAPIProtocolError.malformed(
                "tool_choice requires at least one tool."
            )
        case .function(let name) where !tools.contains(where: { $0.name == name }):
            throw LocalAPIProtocolError.malformed(
                "tool_choice references unknown function '\(name)'."
            )
        default:
            return choice
        }
    }

    private static func decodeMessages(_ rows: [[String: Any]]) throws -> [ChatMessage] {
        try rows.map { row in
            guard let roleString = row["role"] as? String else {
                throw LocalAPIProtocolError.malformed("Every message must include a role.")
            }
            switch roleString {
            case "system", "developer":
                guard let content = try decodeOpenAIContent(row["content"]) else {
                    throw LocalAPIProtocolError.unsupported(
                        "System message content must be text or an array of text parts."
                    )
                }
                return ChatMessage(role: .system, content: content)
            case "user":
                guard let content = try decodeOpenAIContent(row["content"]) else {
                    throw LocalAPIProtocolError.unsupported(
                        "User message content must be text or an array of text parts."
                    )
                }
                return ChatMessage(role: .user, content: content)
            case "assistant":
                let content = try decodeOpenAIContent(row["content"])
                let calls = row["tool_calls"] as? [[String: Any]] ?? []
                guard content?.isEmpty == false || !calls.isEmpty else {
                    throw LocalAPIProtocolError.unsupported(
                        "Assistant messages must contain text or tool_calls."
                    )
                }
                let summaries = try calls.map { call -> String in
                    guard let function = call["function"] as? [String: Any],
                          let name = function["name"] as? String,
                          let arguments = encodedJSONObject(
                            function["arguments"] ?? function["parameters"]
                          ) else {
                        throw LocalAPIProtocolError.malformed(
                            "Assistant tool_calls must contain a function name and arguments."
                        )
                    }
                    let id = call["id"] as? String ?? "unknown"
                    return "call_id=\(id) name=\(name) arguments=\(arguments)"
                }
                var parts: [String] = []
                if let content, !content.isEmpty {
                    parts.append(content)
                }
                if !summaries.isEmpty {
                    parts.append("[Previous tool calls]\n" + summaries.joined(separator: "\n"))
                }
                return ChatMessage(
                    role: .assistant,
                    content: parts.joined(separator: "\n\n")
                )
            case "tool":
                guard let content = try decodeOpenAIContent(row["content"]) else {
                    throw LocalAPIProtocolError.unsupported(
                        "Tool message content must be text or an array of text parts."
                    )
                }
                let id = row["tool_call_id"] as? String ?? "unknown"
                return ChatMessage(
                    role: .user,
                    content: "[Tool result for call_id=\(id)]\n\(content)"
                )
            default:
                throw LocalAPIProtocolError.unsupported("Message role '\(roleString)' is not supported.")
            }
        }
    }

    private static func decodeOpenAIContent(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else {
            throw LocalAPIProtocolError.unsupported(
                "Message content must be text or an array of text parts."
            )
        }
        return try blocks.map { block in
            let type = block["type"] as? String
            guard ["text", "input_text", "output_text"].contains(type),
                  let text = block["text"] as? String else {
                throw LocalAPIProtocolError.unsupported(
                    "Only text content parts are supported in chat messages."
                )
            }
            return text
        }.joined(separator: "\n")
    }

    private static func decodeResponseInput(_ rows: [[String: Any]]) throws -> [ChatMessage] {
        try rows.map { row in
            guard row["type"] as? String == nil || row["type"] as? String == "message",
                  let roleString = row["role"] as? String,
                  let content = try decodeResponseContent(row["content"]),
                  !content.isEmpty else {
                throw LocalAPIProtocolError.unsupported(
                    "Only text message items are supported in Responses API input."
                )
            }
            let role: ChatMessage.Role
            switch roleString {
            case "developer", "system": role = .system
            case "user": role = .user
            case "assistant": role = .assistant
            default:
                throw LocalAPIProtocolError.unsupported("Message role '\(roleString)' is not supported.")
            }
            return ChatMessage(role: role, content: content)
        }
    }

    private static func decodeResponseContent(_ value: Any?) throws -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        return try blocks.map { block in
            let type = block["type"] as? String
            guard ["input_text", "output_text", "text"].contains(type),
                  let text = block["text"] as? String else {
                throw LocalAPIProtocolError.unsupported(
                    "Only input_text and output_text content blocks are supported."
                )
            }
            return text
        }.joined(separator: "\n")
    }

    private static func decodeAnthropicContent(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else {
            throw LocalAPIProtocolError.unsupported("Only text content is supported.")
        }
        return try blocks.map { block in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String else {
                throw LocalAPIProtocolError.unsupported("Only Anthropic text content blocks are supported.")
            }
            return text
        }.joined(separator: "\n")
    }

    private static func decodeAnthropicMessageContent(_ value: Any?) throws -> String? {
        if let text = value as? String { return text }
        guard let blocks = value as? [[String: Any]] else { return nil }
        return try blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text":
                return block["text"] as? String
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let input = encodedJSONObject(block["input"]) else {
                    throw LocalAPIProtocolError.malformed(
                        "Anthropic tool_use requires id, name, and input."
                    )
                }
                return "[Previous tool call]\ncall_id=\(id) name=\(name) arguments=\(input)"
            case "tool_result":
                guard let id = block["tool_use_id"] as? String,
                      let content = try decodeAnthropicContent(block["content"]) else {
                    throw LocalAPIProtocolError.malformed(
                        "Anthropic tool_result requires tool_use_id and content."
                    )
                }
                return "[Tool result available for call_id=\(id)]\n\(content)"
            default:
                throw LocalAPIProtocolError.unsupported(
                    "Unsupported Anthropic message content block."
                )
            }
        }.joined(separator: "\n\n")
    }

    private static func encodedJSONObject(_ value: Any?) -> String? {
        if let string = value as? String {
            guard let data = string.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                return nil
            }
            return string
        }
        let object = value ?? [:]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

enum LocalAPIToolCalling {
    /// Tool JSON must be buffered until it is complete so it can be emitted
    /// using the provider's native tool-call shape. Ordinary prose should not
    /// be buffered: doing so makes streaming clients appear frozen.
    static func shouldBufferForToolDecision(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let toolPrefixes = ["{", "<tool_call", "```json", "```"]
        let couldBeToolCall = toolPrefixes.contains {
            trimmed.hasPrefix($0) || $0.hasPrefix(trimmed)
        }
        guard couldBeToolCall else { return false }

        // Some models begin an ordinary answer with JSON or a fenced block.
        // Once enough of the prefix is present to show that it is not using
        // our tool-call envelope, stream it as prose instead of buffering the
        // entire generation and making agent UIs appear frozen.
        let decisionPrefix = String(trimmed.prefix(160))
        if decisionPrefix.count >= 64,
           !decisionPrefix.contains("\"tool_calls\""),
           !decisionPrefix.contains("\"name\""),
           !decisionPrefix.contains("<tool_call") {
            return false
        }
        return true
    }

    static func messages(
        from messages: [ChatMessage],
        tools: [LocalAPIToolDefinition],
        choice: LocalAPIToolChoice,
        parallelToolCalls: Bool
    ) -> [ChatMessage] {
        guard !tools.isEmpty, choice != .none else { return messages }

        let toolList = tools.map { tool in
            var line = "- \(tool.name)"
            if let description = tool.description, !description.isEmpty {
                line += ": \(description)"
            }
            return line + "\n  parameters: \(tool.parametersJSON)"
        }.joined(separator: "\n")

        let choiceInstruction: String
        let hasToolResult = messages.contains {
            $0.content.contains("[Tool result")
                || $0.content.contains("TOOL RESULT:")
        }
        switch choice {
        case .auto:
            choiceInstruction = hasToolResult
                ? "A requested tool has finished and its result is present. Answer naturally using it now. Call another tool only if the result is insufficient."
                : "Call a tool when it is needed to answer the user. Otherwise answer normally."
        case .required:
            choiceInstruction = "You must call at least one available tool."
        case .function(let name):
            choiceInstruction = "You must call the function named \(name)."
        case .none:
            return messages
        }
        let countInstruction = parallelToolCalls
            ? "You may include multiple calls when they can run in parallel."
            : "Return exactly one tool call at a time."
        let protocolPrompt = """
        You can call external functions. \(choiceInstruction)
        \(countInstruction)
        To call functions, output only valid JSON in this exact shape and no markdown:
        {"tool_calls":[{"name":"function_name","arguments":{"argument":"value"}}]}
        Never invent a function name or execute the function yourself. The client executes calls and sends their results back as tool messages. After a tool result is present, it is already complete: answer the user normally and never say you are still waiting for it, unless another call is genuinely necessary.

        Available functions:
        \(toolList)
        """

        let systemInstructions = messages
            .filter { $0.role == .system }
            .map(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        var result = messages.filter { $0.role != .system }
        if let userIndex = result.lastIndex(where: { $0.role == .user }) {
            var user = result[userIndex]
            var sections: [String] = []
            if !systemInstructions.isEmpty {
                sections.append("[Agent instructions]\n\(systemInstructions)")
            }
            sections.append("[Tool calling instructions]\n\(protocolPrompt)")
            sections.append("[Current user or tool message]\n\(user.content)")
            user.content = sections.joined(separator: "\n\n")
            result[userIndex] = user
        } else {
            let content = systemInstructions.isEmpty
                ? protocolPrompt
                : "[Agent instructions]\n\(systemInstructions)\n\n\(protocolPrompt)"
            result.append(ChatMessage(role: .user, content: content))
        }
        return result
    }

    static func parse(
        _ output: String,
        tools: [LocalAPIToolDefinition],
        parallelToolCalls: Bool
    ) -> [LocalAPIToolCall] {
        let validNames = Set(tools.map(\.name))
        guard !validNames.isEmpty else { return [] }

        var parsedCalls: [LocalAPIToolCall] = []
        for data in candidateJSONObjects(in: output) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawCalls: [[String: Any]]
            if let calls = object["tool_calls"] as? [[String: Any]] {
                rawCalls = calls
            } else {
                rawCalls = [object]
            }

            for rawCall in rawCalls {
                let function = rawCall["function"] as? [String: Any] ?? rawCall
                guard let name = function["name"] as? String,
                      validNames.contains(name),
                      let argumentsJSON = normalizedArguments(
                        function["arguments"]
                            ?? function["parameters"]
                            ?? function["args"]
                      ) else {
                    continue
                }
                parsedCalls.append(LocalAPIToolCall(
                    id: rawCall["id"] as? String
                        ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                    name: name,
                    argumentsJSON: argumentsJSON
                ))
                if !parallelToolCalls { return parsedCalls }
            }
        }
        return parsedCalls
    }

    private static func normalizedArguments(_ value: Any?) -> String? {
        if let string = value as? String,
           let data = string.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return string
        }
        let object = value ?? [:]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func candidateJSONObjects(in output: String) -> [Data] {
        let bytes = Array(output.utf8)
        var candidates: [Data] = []
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
                if depth == 0, let startIndex = start {
                    candidates.append(Data(bytes[startIndex...index]))
                    start = nil
                }
            }
        }
        return candidates
    }
}

enum LocalAPIInferencePolicy {
    static let maximumResponseTokens = 4_096
    static let maximumToolSelectionTokens = 256
    static let toolSelectionDeadline: Duration = .seconds(30)
    static let responseDeadline: Duration = .seconds(90)

    static func deadline(toolCallingEnabled: Bool) -> Duration {
        toolCallingEnabled ? toolSelectionDeadline : responseDeadline
    }

    static func maxTokens(requested: Int?, toolCallingEnabled: Bool) -> Int? {
        let ceiling = toolCallingEnabled
            ? maximumToolSelectionTokens
            : maximumResponseTokens
        guard let requested else {
            return toolCallingEnabled ? ceiling : nil
        }
        return min(max(1, requested), ceiling)
    }
}

enum LocalAPIResponse {
    static func openAIChunk(
        id: String,
        model: String,
        text: String,
        role: String? = nil,
        finishReason: String? = nil
    ) -> Data {
        var delta: [String: Any] = text.isEmpty ? [:] : ["content": text]
        if let role {
            delta["role"] = role
        }
        let choice: [String: Any] = [
            "index": 0,
            "delta": delta,
            "finish_reason": finishReason as Any
        ]
        return json([
            "id": id, "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model, "choices": [choice]
        ])
    }

    static func openAIToolCallChunk(
        id: String,
        model: String,
        calls: [LocalAPIToolCall],
        finishReason: String? = nil
    ) -> Data {
        let delta: [String: Any]
        if calls.isEmpty {
            delta = [:]
        } else {
            delta = [
                "role": "assistant",
                "tool_calls": calls.enumerated().map { index, call in
                    [
                        "index": index,
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON
                        ]
                    ] as [String: Any]
                }
            ]
        }
        return json([
            "id": id,
            "object": "chat.completion.chunk",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "delta": delta,
                "finish_reason": finishReason as Any
            ]]
        ])
    }

    static func openAIChatCompletion(
        id: String,
        model: String,
        text: String,
        toolCalls: [LocalAPIToolCall],
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        var message: [String: Any] = ["role": "assistant"]
        if toolCalls.isEmpty {
            message["content"] = text
        } else {
            message["content"] = NSNull()
            message["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.argumentsJSON
                    ]
                ]
            }
        }
        var object: [String: Any] = [
            "id": id,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": toolCalls.isEmpty ? "stop" : "tool_calls"
            ]]
        ]
        if let usage {
            object["usage"] = [
                "prompt_tokens": usage.input,
                "completion_tokens": usage.output,
                "total_tokens": usage.input + usage.output
            ]
        }
        return json(object)
    }

    static func ollamaChat(
        model: String,
        text: String,
        done: Bool,
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        var object: [String: Any] = [
            "model": model,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "message": ["role": "assistant", "content": text],
            "done": done,
            "done_reason": done ? "stop" : NSNull()
        ]
        if done, let usage {
            object["prompt_eval_count"] = usage.input
            object["eval_count"] = usage.output
        }
        return json(object)
    }

    static func ollamaToolCalls(
        model: String,
        calls: [LocalAPIToolCall],
        done: Bool,
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        let toolCalls: [[String: Any]] = calls.map { call in
            let arguments = (try? JSONSerialization.jsonObject(
                with: Data(call.argumentsJSON.utf8)
            )) ?? [:]
            return [
                "function": [
                    "name": call.name,
                    "arguments": arguments
                ]
            ]
        }
        var object: [String: Any] = [
            "model": model,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "message": [
                "role": "assistant",
                "content": "",
                "tool_calls": toolCalls
            ],
            "done": done,
            "done_reason": done ? "stop" : NSNull()
        ]
        if done, let usage {
            object["prompt_eval_count"] = usage.input
            object["eval_count"] = usage.output
        }
        return json(object)
    }

    static func ollamaGenerate(
        model: String,
        text: String,
        done: Bool,
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        var object: [String: Any] = [
            "model": model,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "response": text,
            "done": done,
            "done_reason": done ? "stop" : NSNull()
        ]
        if done, let usage {
            object["prompt_eval_count"] = usage.input
            object["eval_count"] = usage.output
        }
        return json(object)
    }

    static func anthropicMessage(
        id: String,
        model: String,
        text: String,
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        json([
            "id": id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": usage?.input ?? 0,
                "output_tokens": usage?.output ?? 0
            ]
        ])
    }

    static func anthropicToolMessage(
        id: String,
        model: String,
        calls: [LocalAPIToolCall],
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        let content: [[String: Any]] = calls.map { call in
            [
                "type": "tool_use",
                "id": call.id,
                "name": call.name,
                "input": (try? JSONSerialization.jsonObject(
                    with: Data(call.argumentsJSON.utf8)
                )) ?? [:]
            ]
        }
        return json([
            "id": id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": "tool_use",
            "stop_sequence": NSNull(),
            "usage": [
                "input_tokens": usage?.input ?? 0,
                "output_tokens": usage?.output ?? 0
            ]
        ])
    }

    static func openAIResponse(
        id: String,
        model: String,
        text: String,
        status: String = "completed",
        usage: (input: Int, output: Int)? = nil
    ) -> Data {
        json([
            "id": id,
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": status,
            "model": model,
            "output": [[
                "id": "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "type": "message",
                "status": status,
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": text,
                    "annotations": []
                ]]
            ]],
            "output_text": text,
            "error": NSNull(),
            "incomplete_details": NSNull(),
            "usage": [
                "input_tokens": usage?.input ?? 0,
                "output_tokens": usage?.output ?? 0,
                "total_tokens": (usage?.input ?? 0) + (usage?.output ?? 0)
            ]
        ])
    }

    static func openAIResponseEvent(_ type: String, fields: [String: Any]) -> Data {
        var object = fields
        object["type"] = type
        return Data("event: \(type)\ndata: ".utf8) + json(object) + Data("\n\n".utf8)
    }

    static func anthropicEvent(_ name: String, object: Any) -> Data {
        let payload = json(object)
        return Data("event: \(name)\ndata: ".utf8) + payload + Data("\n\n".utf8)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

actor LocalAPIServer {
    enum Event: Sendable {
        case ready
        case failed(String)
    }

    private var listener: NWListener?
    private var listenerID: UUID?
    private struct ActiveInference {
        let id: UUID
        let signal: LocalAPIInferenceSignal
        var timedOut = false
    }
    private var activeInference: ActiveInference?
    private let maxRequestBytes = 4 * 1024 * 1024
    private let requestTimeout: TimeInterval = 15

    /// Brute-force guard on bearer authentication, mirroring the
    /// `/v1/pair` lockout in BridgeServer.
    private var failedAuthAttempts: [Date] = []
    private var authLockedUntil: Date?
    private static let maxFailedAuthAttempts = 5
    private static let authAttemptWindow: TimeInterval = 60
    private static let authLockoutDuration: TimeInterval = 60

    var onEvent: (@Sendable (Event) -> Void)?

    func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        onEvent = handler
    }

    func start(port: UInt16) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Opt-in: AWDL advertisement reaches nearby devices that are not
        // on the user's network. The API is designed for the trusted LAN.
        params.includePeerToPeer = AppSettings.shared.localAPIIncludePeerToPeer
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalAPIProtocolError.malformed("Invalid port")
        }
        let newListener = try NWListener(using: params, on: endpointPort)
        let newListenerID = UUID()
        newListener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state, listenerID: newListenerID) }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handle(connection) }
        }
        listener = newListener
        listenerID = newListenerID
        newListener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listenerID = nil
    }

    private func listenerChanged(_ state: NWListener.State, listenerID: UUID) {
        guard self.listenerID == listenerID else { return }
        switch state {
        case .ready:
            onEvent?(.ready)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            self.listenerID = nil
            onEvent?(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        do {
            let request = try await readRequest(connection)
            await route(request, connection: connection)
        } catch {
            connection.cancel()
        }
    }

    private func readRequest(_ connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(requestTimeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw LocalAPIProtocolError.malformed("Request timed out") }
            let chunk = try await receive(connection, timeout: remaining)
            guard !chunk.isEmpty else { throw LocalAPIProtocolError.malformed("Connection closed") }
            buffer.append(chunk)
            guard buffer.count <= maxRequestBytes else {
                throw LocalAPIProtocolError.malformed("Request too large")
            }
            if let request = HTTPRequest(data: buffer) { return request }
        }
    }

    private func receive(_ connection: NWConnection, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let once = LocalAPIResumeOnce(continuation)
            // Deadline task is created first and cancelled by the receive
            // callback, so a fast multi-chunk request does not pile up
            // sleeping timeout tasks that each hold the connection alive.
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeout))
                if once.resume(throwing: LocalAPIProtocolError.malformed("Request timed out")) {
                    connection.cancel()
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                data, _, _, error in
                timeoutTask.cancel()
                if let error { once.resume(throwing: error) }
                else { once.resume(returning: data ?? Data()) }
            }
        }
    }

    private func route(_ request: HTTPRequest, connection: NWConnection) async {
        let corsOrigin = LocalAPIValidation.allowedCORSOrigin(
            origin: request.headers["origin"],
            settingValue: AppSettings.shared.localAPICORSOrigins
        )
        // Browser clients send a preflight before requests carrying
        // Authorization / x-api-key. Answer it before authentication so web
        // agents can reach the same local endpoint as terminal clients;
        // unapproved origins get no CORS headers and browsers block them.
        if request.method == "OPTIONS" {
            await respond(
                connection,
                status: 204,
                contentType: "text/plain",
                data: Data(),
                corsOrigin: corsOrigin
            )
            return
        }
        if let locked = authLockedUntil, locked > Date() {
            await error(connection, status: 429, message: "Too many failed attempts; retry later", dialect: request.path == "/v1/messages" ? .anthropic : .openAIChat, corsOrigin: corsOrigin)
            return
        }
        let key = LocalAPIKeyStore.key()
        let presentedBearer = request.headers["authorization"].flatMap {
            $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil
        }
        let authorized = (presentedBearer.map { Self.tokensMatch($0, key) } ?? false)
            || (request.headers["x-api-key"].map { Self.tokensMatch($0, key) } ?? false)
        guard authorized else {
            recordFailedAuthAttempt()
            await error(connection, status: 401, message: "Invalid or missing API key", dialect: request.path == "/v1/messages" ? .anthropic : .openAIChat, corsOrigin: corsOrigin)
            return
        }
        failedAuthAttempts.removeAll()
        authLockedUntil = nil
        switch (request.method, request.path) {
        case ("GET", "/v1/models"):
            await listOpenAIModels(connection, corsOrigin: corsOrigin)
        case ("POST", "/v1/chat/completions"):
            await run(request, connection: connection, dialect: .openAIChat)
        case ("POST", "/v1/responses"):
            await run(request, connection: connection, dialect: .openAIResponses)
        case ("POST", "/v1/messages"):
            await run(request, connection: connection, dialect: .anthropic)
        case ("GET", "/api/tags"):
            await listOllamaModels(connection, corsOrigin: corsOrigin)
        case ("POST", "/api/show"):
            await showOllamaModel(request, connection: connection)
        case ("POST", "/api/chat"):
            await run(request, connection: connection, dialect: .ollamaChat)
        case ("POST", "/api/generate"):
            await run(request, connection: connection, dialect: .ollamaGenerate)
        default:
            await error(connection, status: 404, message: "Endpoint not supported", dialect: request.path == "/v1/messages" ? .anthropic : .openAIChat, corsOrigin: corsOrigin)
        }
    }

    private enum Dialect { case openAIChat, openAIResponses, anthropic, ollamaChat, ollamaGenerate }

    /// Constant-time comparison of SHA-256 digests so a timing side
    /// channel cannot reveal how much of the bearer key matched.
    private static func tokensMatch(_ presented: String, _ key: String) -> Bool {
        let presentedDigest = SHA256.hash(data: Data(presented.utf8))
        let keyDigest = SHA256.hash(data: Data(key.utf8))
        // XOR-accumulate every digest byte; no early exit on mismatch.
        var diff = UInt8(0)
        for (a, b) in zip(presentedDigest, keyDigest) {
            diff |= a ^ b
        }
        return diff == 0
    }

    private func recordFailedAuthAttempt() {
        let cutoff = Date().addingTimeInterval(-Self.authAttemptWindow)
        failedAuthAttempts.removeAll { $0 < cutoff }
        failedAuthAttempts.append(Date())
        if failedAuthAttempts.count >= Self.maxFailedAuthAttempts {
            authLockedUntil = Date().addingTimeInterval(Self.authLockoutDuration)
            failedAuthAttempts.removeAll()
        }
    }

    private func run(_ request: HTTPRequest, connection: NWConnection, dialect: Dialect) async {
        let corsOrigin = LocalAPIValidation.allowedCORSOrigin(
            origin: request.headers["origin"],
            settingValue: AppSettings.shared.localAPICORSOrigins
        )
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            await error(connection, status: 415, message: "Content-Type must be application/json", dialect: dialect, corsOrigin: corsOrigin)
            return
        }
        guard let body = request.body else {
            await error(connection, status: 400, message: "JSON body required", dialect: dialect, corsOrigin: corsOrigin)
            return
        }
        let decoded: LocalAPIChatRequest
        do {
            switch dialect {
            case .openAIChat: decoded = try .decodeOpenAI(body)
            case .openAIResponses: decoded = try .decodeOpenAIResponses(body)
            case .anthropic: decoded = try .decodeAnthropic(body)
            case .ollamaChat: decoded = try .decodeOllamaChat(body)
            case .ollamaGenerate: decoded = try .decodeOllamaGenerate(body)
            }
        } catch let error as LocalAPIProtocolError {
            let message: String
            switch error {
            case .malformed(let value), .unsupported(let value): message = value
            case .unknownModel: message = "Unknown model"
            }
            await self.error(connection, status: 400, message: message, dialect: dialect, corsOrigin: corsOrigin)
            return
        } catch {
            await self.error(connection, status: 400, message: "Malformed request", dialect: dialect, corsOrigin: corsOrigin)
            return
        }

        let snapshot = await MainActor.run { () -> (String, String, Bool) in
            let service = CodingAssistantService.shared
            return (service.activeModel.id, service.activeModel.repoID, service.state == .ready)
        }
        let usesCurrentOllamaModel = decoded.model.isEmpty
            && (dialect == .ollamaChat || dialect == .ollamaGenerate)
        guard usesCurrentOllamaModel
                || LocalAPIValidation.modelMatches(decoded.model, id: snapshot.0, repoID: snapshot.1) else {
            // Fixed message: echoing the requested model name reflects
            // attacker-controlled input back into the response.
            await error(connection, status: 404, message: "Unknown or unloaded model", dialect: dialect, corsOrigin: corsOrigin)
            return
        }
        guard snapshot.2 else {
            await error(connection, status: 503, message: "The active model is not loaded or is busy", dialect: dialect, corsOrigin: corsOrigin)
            return
        }
        guard let lease = await RemoteInferenceGate.shared.acquire() else {
            await error(connection, status: 503, message: "Model busy", dialect: dialect, corsOrigin: corsOrigin)
            return
        }

        let toolCallingEnabled = (
            dialect == .openAIChat
                || dialect == .anthropic
                || dialect == .ollamaChat
        )
            && !decoded.tools.isEmpty
            && decoded.toolChoice != .none
        let inferenceID = UUID()
        let inferenceSignal = LocalAPIInferenceSignal()
        activeInference = ActiveInference(id: inferenceID, signal: inferenceSignal)
        let disconnectTask = Task { [weak self] in
            await self?.monitorDisconnect(connection, inferenceID: inferenceID)
        }
        let inferenceDeadline = LocalAPIInferencePolicy.deadline(
            toolCallingEnabled: toolCallingEnabled
        )
        let deadlineReason = toolCallingEnabled
            ? "tool-selection deadline"
            : "response deadline"
        let deadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: inferenceDeadline)
                await self?.cancelInference(
                    inferenceID: inferenceID,
                    reason: deadlineReason,
                    timedOut: true
                )
            } catch {
                // Normal completion cancels this deadline task.
            }
        }
        defer {
            if activeInference?.id == inferenceID {
                activeInference = nil
            }
            disconnectTask.cancel()
            deadlineTask.cancel()
            Task { await RemoteInferenceGate.shared.release(lease) }
        }

        let maxTokens = LocalAPIInferencePolicy.maxTokens(
            requested: decoded.maxTokens,
            toolCallingEnabled: toolCallingEnabled
        )
        let temperature = decoded.temperature.map { min(max(0, $0), 2) }
        let topP = decoded.topP.map { min(max(0, $0), 1) }
        let inferenceMessages = LocalAPIToolCalling.messages(
            from: decoded.messages,
            tools: decoded.tools,
            choice: decoded.toolChoice,
            parallelToolCalls: decoded.parallelToolCalls
        )
        let stream = await inferenceStream(
            messages: inferenceMessages,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            signal: inferenceSignal
        )

        if decoded.stream {
            await writeStreamingHeaders(connection, dialect: dialect, model: snapshot.0, corsOrigin: corsOrigin)
            let requestID = dialect == .openAIResponses
                ? "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                : "chatcmpl-\(UUID().uuidString)"
            if toolCallingEnabled {
                var output = ""
                var calls: [LocalAPIToolCall] = []
                var streamsAsText = false
                do {
                    for await token in stream {
                        output += token
                        if streamsAsText {
                            try await sendToolAwareTextDelta(
                                connection,
                                dialect: dialect,
                                model: snapshot.0,
                                requestID: requestID,
                                text: token,
                                startsStream: false
                            )
                            continue
                        }
                        if token.contains("}") {
                            calls = LocalAPIToolCalling.parse(
                                output,
                                tools: decoded.tools,
                                parallelToolCalls: decoded.parallelToolCalls
                            )
                            if !calls.isEmpty {
                                await cancelInference()
                                break
                            }
                        }
                        if !LocalAPIToolCalling.shouldBufferForToolDecision(output) {
                            streamsAsText = true
                            try await sendToolAwareTextDelta(
                                connection,
                                dialect: dialect,
                                model: snapshot.0,
                                requestID: requestID,
                                text: output,
                                startsStream: true
                            )
                        }
                    }
                    if let failure = inferenceSignal.failure, !streamsAsText, calls.isEmpty {
                        try? await sendFinal(
                            connection,
                            streamingErrorPayload(dialect: dialect, message: failure)
                        )
                        connection.cancel()
                        return
                    }
                    if streamsAsText {
                        try await finishToolAwareTextStream(
                            connection,
                            dialect: dialect,
                            model: snapshot.0,
                            requestID: requestID
                        )
                        connection.cancel()
                        return
                    }
                    if calls.isEmpty {
                        calls = LocalAPIToolCalling.parse(
                            output,
                            tools: decoded.tools,
                            parallelToolCalls: decoded.parallelToolCalls
                        )
                    }
                    if calls.isEmpty,
                       activeInference?.id == inferenceID,
                       activeInference?.timedOut == true {
                        output = "The on-device model did not finish a valid tool call within 30 seconds. Please retry with a smaller context or model."
                    }
                    if calls.isEmpty {
                        switch dialect {
                        case .openAIChat:
                            try await send(
                                connection,
                                Data("data: ".utf8)
                                    + LocalAPIResponse.openAIChunk(
                                        id: requestID,
                                        model: snapshot.0,
                                        text: output
                                    )
                                    + Data("\n\n".utf8)
                            )
                            try await sendFinal(
                                connection,
                                Data("data: ".utf8)
                                    + LocalAPIResponse.openAIChunk(
                                        id: requestID,
                                        model: snapshot.0,
                                        text: "",
                                        finishReason: "stop"
                                    )
                                    + Data("\n\ndata: [DONE]\n\n".utf8)
                            )
                        case .anthropic:
                            try await sendAnthropicTextCompletion(
                                connection,
                                text: output
                            )
                        case .ollamaChat:
                            try await sendFinal(
                                connection,
                                LocalAPIResponse.ollamaChat(
                                    model: snapshot.0,
                                    text: output,
                                    done: true
                                )
                                    + Data("\n".utf8)
                            )
                        case .openAIResponses, .ollamaGenerate:
                            break
                        }
                    } else {
                        switch dialect {
                        case .openAIChat:
                            try await send(
                                connection,
                                Data("data: ".utf8)
                                    + LocalAPIResponse.openAIToolCallChunk(
                                        id: requestID,
                                        model: snapshot.0,
                                        calls: calls
                                    )
                                    + Data("\n\n".utf8)
                            )
                            try await sendFinal(
                                connection,
                                Data("data: ".utf8)
                                    + LocalAPIResponse.openAIToolCallChunk(
                                        id: requestID,
                                        model: snapshot.0,
                                        calls: [],
                                        finishReason: "tool_calls"
                                    )
                                    + Data("\n\ndata: [DONE]\n\n".utf8)
                            )
                        case .anthropic:
                            try await sendAnthropicToolCompletion(
                                connection,
                                calls: calls
                            )
                        case .ollamaChat:
                            try await sendFinal(
                                connection,
                                LocalAPIResponse.ollamaToolCalls(
                                    model: snapshot.0,
                                    calls: calls,
                                    done: true
                                )
                                    + Data("\n".utf8)
                            )
                        case .openAIResponses, .ollamaGenerate:
                            break
                        }
                    }
                } catch {
                    await cancelInference()
                    connection.cancel()
                    return
                }
                connection.cancel()
                return
            }
            if dialect == .anthropic {
                try? await send(connection, LocalAPIResponse.anthropicEvent(
                    "content_block_start",
                    object: [
                        "type": "content_block_start",
                        "index": 0,
                        "content_block": ["type": "text", "text": ""]
                    ]
                ))
            } else if dialect == .openAIChat {
                // OpenAI-compatible browser/agent SDKs use the first delta to
                // establish the assistant message. Terminal parsers were
                // permissive when this role chunk was absent; several web
                // clients wait indefinitely for it.
                try? await send(
                    connection,
                    Data("data: ".utf8)
                        + LocalAPIResponse.openAIChunk(
                            id: requestID,
                            model: snapshot.0,
                            text: "",
                            role: "assistant"
                        )
                        + Data("\n\n".utf8)
                )
            }
            var streamedOutput = ""
            for await token in stream {
                streamedOutput += token
                let payload: Data
                switch dialect {
                case .openAIChat:
                    payload = Data("data: ".utf8) + LocalAPIResponse.openAIChunk(id: requestID, model: snapshot.0, text: token) + Data("\n\n".utf8)
                case .openAIResponses:
                    payload = LocalAPIResponse.openAIResponseEvent("response.output_text.delta", fields: [
                        "response_id": requestID,
                        "item_id": "msg_\(requestID)",
                        "output_index": 0,
                        "content_index": 0,
                        "delta": token
                    ])
                case .anthropic:
                    payload = LocalAPIResponse.anthropicEvent("content_block_delta", object: [
                        "type": "content_block_delta",
                        "index": 0,
                        "delta": ["type": "text_delta", "text": token]
                    ])
                case .ollamaChat:
                    payload = LocalAPIResponse.ollamaChat(model: snapshot.0, text: token, done: false) + Data("\n".utf8)
                case .ollamaGenerate:
                    payload = LocalAPIResponse.ollamaGenerate(model: snapshot.0, text: token, done: false) + Data("\n".utf8)
                }
                do { try await send(connection, payload) }
                catch { await cancelInference(); connection.cancel(); return }
            }
            if let failure = inferenceSignal.failure, streamedOutput.isEmpty {
                try? await sendFinal(
                    connection,
                    streamingErrorPayload(dialect: dialect, message: failure)
                )
                connection.cancel()
                return
            }
            switch dialect {
            case .openAIChat:
                try? await sendFinal(connection, Data("data: ".utf8) + LocalAPIResponse.openAIChunk(id: requestID, model: snapshot.0, text: "", finishReason: "stop") + Data("\n\ndata: [DONE]\n\n".utf8))
            case .openAIResponses:
                try? await send(connection, LocalAPIResponse.openAIResponseEvent("response.output_text.done", fields: [
                    "response_id": requestID,
                    "item_id": "msg_\(requestID)",
                    "output_index": 0,
                    "content_index": 0,
                    "text": streamedOutput
                ]))
                try? await sendFinal(connection, LocalAPIResponse.openAIResponseEvent("response.completed", fields: [
                    "response": (try? JSONSerialization.jsonObject(with: LocalAPIResponse.openAIResponse(
                        id: requestID,
                        model: snapshot.0,
                        text: streamedOutput,
                        usage: inferenceSignal.usage
                    ))) ?? [:]
                ]))
            case .anthropic:
                try? await send(connection, LocalAPIResponse.anthropicEvent("content_block_stop", object: [
                    "type": "content_block_stop", "index": 0
                ]))
                try? await send(connection, LocalAPIResponse.anthropicEvent("message_delta", object: [
                    "type": "message_delta",
                    "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                    "usage": ["output_tokens": inferenceSignal.usage.output]
                ]))
                try? await sendFinal(connection, LocalAPIResponse.anthropicEvent("message_stop", object: [
                    "type": "message_stop"
                ]))
            case .ollamaChat:
                try? await sendFinal(connection, LocalAPIResponse.ollamaChat(model: snapshot.0, text: "", done: true, usage: inferenceSignal.usage) + Data("\n".utf8))
            case .ollamaGenerate:
                try? await sendFinal(connection, LocalAPIResponse.ollamaGenerate(model: snapshot.0, text: "", done: true, usage: inferenceSignal.usage) + Data("\n".utf8))
            }
            connection.cancel()
        } else {
            var output = ""
            var detectedCalls: [LocalAPIToolCall] = []
            for await token in stream {
                output += token
                if toolCallingEnabled, token.contains("}") {
                    detectedCalls = LocalAPIToolCalling.parse(
                        output,
                        tools: decoded.tools,
                        parallelToolCalls: decoded.parallelToolCalls
                    )
                    if !detectedCalls.isEmpty {
                        await cancelInference()
                        break
                    }
                }
            }
            if let failure = inferenceSignal.failure, output.isEmpty, detectedCalls.isEmpty {
                await error(connection, status: 500, message: failure, dialect: dialect, corsOrigin: corsOrigin)
                return
            }
            let usage = inferenceSignal.usage
            let payload: Data
            switch dialect {
            case .openAIChat:
                let calls = toolCallingEnabled
                    ? detectedCalls.isEmpty ? LocalAPIToolCalling.parse(
                        output,
                        tools: decoded.tools,
                        parallelToolCalls: decoded.parallelToolCalls
                    ) : detectedCalls
                    : []
                payload = LocalAPIResponse.openAIChatCompletion(
                    id: "chatcmpl-\(UUID().uuidString)",
                    model: snapshot.0,
                    text: output,
                    toolCalls: calls,
                    usage: usage
                )
            case .openAIResponses:
                payload = LocalAPIResponse.openAIResponse(
                    id: "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                    model: snapshot.0,
                    text: output,
                    usage: usage
                )
            case .anthropic:
                let calls = toolCallingEnabled
                    ? detectedCalls.isEmpty ? LocalAPIToolCalling.parse(
                        output,
                        tools: decoded.tools,
                        parallelToolCalls: false
                    ) : detectedCalls
                    : []
                payload = calls.isEmpty
                    ? LocalAPIResponse.anthropicMessage(
                        id: "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                        model: snapshot.0,
                        text: output,
                        usage: usage
                    )
                    : LocalAPIResponse.anthropicToolMessage(
                        id: "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                        model: snapshot.0,
                        calls: calls,
                        usage: usage
                    )
            case .ollamaChat:
                let calls = toolCallingEnabled
                    ? detectedCalls.isEmpty ? LocalAPIToolCalling.parse(
                        output,
                        tools: decoded.tools,
                        parallelToolCalls: false
                    ) : detectedCalls
                    : []
                payload = calls.isEmpty
                    ? LocalAPIResponse.ollamaChat(
                        model: snapshot.0,
                        text: output,
                        done: true,
                        usage: usage
                    )
                    : LocalAPIResponse.ollamaToolCalls(
                        model: snapshot.0,
                        calls: calls,
                        done: true,
                        usage: usage
                    )
            case .ollamaGenerate:
                payload = LocalAPIResponse.ollamaGenerate(model: snapshot.0, text: output, done: true, usage: usage)
            }
            await respond(connection, status: 200, contentType: "application/json", data: payload, corsOrigin: corsOrigin)
        }
    }

    private func inferenceStream(
        messages: [ChatMessage],
        maxTokens: Int?,
        temperature: Double?,
        topP: Double?,
        signal: LocalAPIInferenceSignal
    ) async -> AsyncStream<String> {
        AsyncStream { continuation in
            signal.attach(continuation)
            Task { @MainActor in
                CodingAssistantService.shared.generate(
                    messages: messages,
                    maxTokensOverride: maxTokens,
                    temperatureOverride: temperature,
                    topPOverride: topP,
                    onToken: { token in
                        signal.noteOutputToken()
                        continuation.yield(token)
                    },
                    onComplete: { _ in
                        // Usage lives on the MainActor service; hop so the
                        // final snapshot is captured before the stream
                        // closes and callers read `signal.usage`.
                        Task { @MainActor in
                            let service = CodingAssistantService.shared
                            let input = service.lastPromptTokens > 0
                                ? service.lastPromptTokens
                                : service.estimatedInputTokens
                            if service.lastOutputTokens > 0 {
                                signal.setUsage(input: input, output: service.lastOutputTokens)
                            } else {
                                signal.setUsage(input: input, output: signal.usage.output)
                            }
                            signal.finish()
                        }
                    },
                    onError: { message in signal.fail(message) }
                )
            }
            continuation.onTermination = { _ in
                Task { @MainActor in CodingAssistantService.shared.stopGeneration() }
            }
        }
    }

    /// Dialect-appropriate in-stream error frame for SSE responses that
    /// already sent 200 + streaming headers and cannot switch to an HTTP
    /// error status anymore.
    private func streamingErrorPayload(dialect: Dialect, message: String) -> Data {
        switch dialect {
        case .openAIChat, .openAIResponses:
            return Data("data: ".utf8)
                + LocalAPIResponse.json(["error": ["message": message, "type": "server_error"]])
                + Data("\n\n".utf8)
        case .anthropic:
            return LocalAPIResponse.anthropicEvent("error", object: [
                "type": "error",
                "error": ["type": "api_error", "message": message]
            ])
        case .ollamaChat, .ollamaGenerate:
            return LocalAPIResponse.json(["error": message]) + Data("\n".utf8)
        }
    }

    private func cancelInference() async {
        await MainActor.run { CodingAssistantService.shared.stopGeneration() }
    }

    private func cancelInference(
        inferenceID: UUID,
        reason: String,
        timedOut: Bool = false
    ) async {
        guard activeInference?.id == inferenceID else { return }
        if timedOut {
            activeInference?.timedOut = true
        }
        print("[LocalAPIServer] Cancelling inference: \(reason)")
        // End the HTTP-facing stream immediately. Runtime cancellation is
        // cooperative and some backends do not invoke onComplete until native
        // decode has fully unwound, which previously left clients generating
        // indefinitely after their deadline.
        activeInference?.signal.finish()
        await cancelInference()
    }

    private func monitorDisconnect(
        _ connection: NWConnection,
        inferenceID: UUID
    ) async {
        while !Task.isCancelled {
            let disconnected = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 1_024
                ) { data, _, isComplete, error in
                    continuation.resume(
                        returning: error != nil
                            || isComplete
                            || (data?.isEmpty == true)
                    )
                }
            }
            if disconnected {
                await cancelInference(
                    inferenceID: inferenceID,
                    reason: "client disconnected"
                )
                return
            }
        }
    }

    private func listOpenAIModels(_ connection: NWConnection, corsOrigin: String?) async {
        let model = await MainActor.run { CodingAssistantService.shared.activeModel }
        let payload = LocalAPIResponse.json([
            "object": "list",
            "data": [[
                "id": model.id,
                "object": "model",
                "created": 0,
                "owned_by": "on-device"
            ]]
        ])
        await respond(connection, status: 200, contentType: "application/json", data: payload, corsOrigin: corsOrigin)
    }

    private func listOllamaModels(_ connection: NWConnection, corsOrigin: String?) async {
        let model = await MainActor.run { CodingAssistantService.shared.activeModel }
        let payload = LocalAPIResponse.json([
            "models": [[
                "name": model.id,
                "model": model.id,
                "modified_at": ISO8601DateFormatter().string(from: Date()),
                "size": model.downloadSizeBytes ?? 0,
                "digest": "",
                "details": ["family": model.repoID, "format": model.runtime == .llamaCpp ? "gguf" : "mlx"]
            ]]
        ])
        await respond(connection, status: 200, contentType: "application/json", data: payload, corsOrigin: corsOrigin)
    }

    private func showOllamaModel(_ request: HTTPRequest, connection: NWConnection) async {
        let corsOrigin = LocalAPIValidation.allowedCORSOrigin(
            origin: request.headers["origin"],
            settingValue: AppSettings.shared.localAPICORSOrigins
        )
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let body = request.body,
              let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            await error(connection, status: 400, message: "JSON body required", dialect: .ollamaChat, corsOrigin: corsOrigin)
            return
        }
        let model = await MainActor.run { CodingAssistantService.shared.activeModel }
        let requested = (raw["model"] ?? raw["name"]) as? String
        guard requested == nil || requested?.isEmpty == true
                || LocalAPIValidation.modelMatches(requested!, id: model.id, repoID: model.repoID) else {
            await error(connection, status: 404, message: "Unknown or unloaded model", dialect: .ollamaChat, corsOrigin: corsOrigin)
            return
        }
        let payload = LocalAPIResponse.json([
            "license": "",
            "modelfile": "",
            "parameters": "",
            "template": "",
            "details": [
                "family": model.repoID,
                "format": model.runtime == .llamaCpp ? "gguf" : "mlx"
            ],
            "model_info": ["general.architecture": model.repoID]
        ])
        await respond(connection, status: 200, contentType: "application/json", data: payload, corsOrigin: corsOrigin)
    }

    private func sendToolAwareTextDelta(
        _ connection: NWConnection,
        dialect: Dialect,
        model: String,
        requestID: String,
        text: String,
        startsStream: Bool
    ) async throws {
        switch dialect {
        case .openAIChat:
            try await sendFinal(
                connection,
                Data("data: ".utf8)
                    + LocalAPIResponse.openAIChunk(
                        id: requestID,
                        model: model,
                        text: text,
                        role: startsStream ? "assistant" : nil
                    )
                    + Data("\n\n".utf8)
            )
        case .anthropic:
            if startsStream {
                try await send(connection, LocalAPIResponse.anthropicEvent(
                    "content_block_start",
                    object: [
                        "type": "content_block_start",
                        "index": 0,
                        "content_block": ["type": "text", "text": ""]
                    ]
                ))
            }
            try await send(connection, LocalAPIResponse.anthropicEvent(
                "content_block_delta",
                object: [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": ["type": "text_delta", "text": text]
                ]
            ))
        case .ollamaChat:
            try await send(
                connection,
                LocalAPIResponse.ollamaChat(
                    model: model,
                    text: text,
                    done: false
                ) + Data("\n".utf8)
            )
        case .openAIResponses, .ollamaGenerate:
            break
        }
    }

    private func finishToolAwareTextStream(
        _ connection: NWConnection,
        dialect: Dialect,
        model: String,
        requestID: String
    ) async throws {
        switch dialect {
        case .openAIChat:
            try await sendFinal(
                connection,
                Data("data: ".utf8)
                    + LocalAPIResponse.openAIChunk(
                        id: requestID,
                        model: model,
                        text: "",
                        finishReason: "stop"
                    )
                    + Data("\n\ndata: [DONE]\n\n".utf8)
            )
        case .anthropic:
            try await send(connection, LocalAPIResponse.anthropicEvent(
                "content_block_stop",
                object: ["type": "content_block_stop", "index": 0]
            ))
            try await send(connection, LocalAPIResponse.anthropicEvent(
                "message_delta",
                object: [
                    "type": "message_delta",
                    "delta": [
                        "stop_reason": "end_turn",
                        "stop_sequence": NSNull()
                    ],
                    "usage": ["output_tokens": 0]
                ]
            ))
            try await sendFinal(connection, LocalAPIResponse.anthropicEvent(
                "message_stop",
                object: ["type": "message_stop"]
            ))
        case .ollamaChat:
            try await sendFinal(
                connection,
                LocalAPIResponse.ollamaChat(
                    model: model,
                    text: "",
                    done: true
                ) + Data("\n".utf8)
            )
        case .openAIResponses, .ollamaGenerate:
            break
        }
    }

    private func sendAnthropicTextCompletion(
        _ connection: NWConnection,
        text: String
    ) async throws {
        try await send(connection, LocalAPIResponse.anthropicEvent(
            "content_block_start",
            object: [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": ""]
            ]
        ))
        try await send(connection, LocalAPIResponse.anthropicEvent(
            "content_block_delta",
            object: [
                "type": "content_block_delta",
                "index": 0,
                "delta": ["type": "text_delta", "text": text]
            ]
        ))
        try await send(connection, LocalAPIResponse.anthropicEvent(
            "content_block_stop",
            object: ["type": "content_block_stop", "index": 0]
        ))
        try await send(connection, LocalAPIResponse.anthropicEvent(
            "message_delta",
            object: [
                "type": "message_delta",
                "delta": [
                    "stop_reason": "end_turn",
                    "stop_sequence": NSNull()
                ],
                "usage": ["output_tokens": 0]
            ]
        ))
        try await sendFinal(connection, LocalAPIResponse.anthropicEvent(
            "message_stop",
            object: ["type": "message_stop"]
        ))
    }

    private func sendAnthropicToolCompletion(
        _ connection: NWConnection,
        calls: [LocalAPIToolCall]
    ) async throws {
        for (index, call) in calls.enumerated() {
            try await send(connection, LocalAPIResponse.anthropicEvent(
                "content_block_start",
                object: [
                    "type": "content_block_start",
                    "index": index,
                    "content_block": [
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": [:]
                    ]
                ]
            ))
            try await send(connection, LocalAPIResponse.anthropicEvent(
                "content_block_delta",
                object: [
                    "type": "content_block_delta",
                    "index": index,
                    "delta": [
                        "type": "input_json_delta",
                        "partial_json": call.argumentsJSON
                    ]
                ]
            ))
            try await send(connection, LocalAPIResponse.anthropicEvent(
                "content_block_stop",
                object: ["type": "content_block_stop", "index": index]
            ))
        }
        try await send(connection, LocalAPIResponse.anthropicEvent(
            "message_delta",
            object: [
                "type": "message_delta",
                "delta": [
                    "stop_reason": "tool_use",
                    "stop_sequence": NSNull()
                ],
                "usage": ["output_tokens": 0]
            ]
        ))
        try await sendFinal(connection, LocalAPIResponse.anthropicEvent(
            "message_stop",
            object: ["type": "message_stop"]
        ))
    }

    private func writeStreamingHeaders(
        _ connection: NWConnection,
        dialect: Dialect,
        model: String,
        corsOrigin: String? = nil
    ) async {
        let contentType = (dialect == .openAIChat || dialect == .openAIResponses || dialect == .anthropic)
            ? "text/event-stream"
            : "application/x-ndjson"
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Cache-Control: no-cache, no-transform\r\n"
        header += "X-Accel-Buffering: no\r\n"
        if let corsOrigin {
            header += "Access-Control-Allow-Origin: \(corsOrigin)\r\n"
            header += "Vary: Origin\r\n"
        }
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Authorization, Content-Type, X-API-Key, Anthropic-Version, Anthropic-Beta\r\n"
        header += "Connection: close\r\n\r\n"
        try? await send(connection, Data(header.utf8))
        if dialect == .anthropic {
            let messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            try? await send(connection, LocalAPIResponse.anthropicEvent("message_start", object: [
                "type": "message_start",
                "message": [
                    "id": messageID, "type": "message", "role": "assistant",
                    "content": [], "model": model,
                    "stop_reason": NSNull(), "stop_sequence": NSNull(),
                    "usage": ["input_tokens": 0, "output_tokens": 0]
                ]
            ]))
        }
    }

    private func error(_ connection: NWConnection, status: Int, message: String, dialect: Dialect, corsOrigin: String? = nil) async {
        let payload: Data
        if dialect == .anthropic {
            payload = LocalAPIResponse.json([
                "type": "error",
                "error": ["type": "invalid_request_error", "message": message]
            ])
        } else if dialect == .openAIChat || dialect == .openAIResponses {
            payload = LocalAPIResponse.json(["error": ["message": message, "type": "invalid_request_error"]])
        } else {
            payload = LocalAPIResponse.json(["error": message])
        }
        await respond(connection, status: status, contentType: "application/json", data: payload, corsOrigin: corsOrigin)
    }

    private func respond(_ connection: NWConnection, status: Int, contentType: String, data: Data, corsOrigin: String? = nil) async {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 415: reason = "Unsupported Media Type"
        case 429: reason = "Too Many Requests"
        case 503: reason = "Service Unavailable"
        default: reason = "Internal Server Error"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(data.count)\r\n"
        if let corsOrigin {
            header += "Access-Control-Allow-Origin: \(corsOrigin)\r\n"
            header += "Vary: Origin\r\n"
        }
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Authorization, Content-Type, X-API-Key, Anthropic-Version, Anthropic-Beta\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(data)
        try? await sendFinal(connection, payload)
        connection.cancel()
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    /// Finish the HTTP response with a graceful write-side close. Calling
    /// `cancel()` after an ordinary send can turn the close into a TCP reset;
    /// command-line clients often tolerate that, while browser fetch/SSE
    /// stacks keep waiting for a clean end-of-stream.
    private func sendFinal(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            )
        }
    }
}

private final class LocalAPIResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning data: Data) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: data)
        return pending != nil
    }

    @discardableResult
    func resume(throwing error: Error) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(throwing: error)
        return pending != nil
    }
}

private final class LocalAPIInferenceSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?
    private var finished = false
    private var failureMessage: String?

    func attach(_ continuation: AsyncStream<String>.Continuation) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.finish()
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Records the generation failure and ends the stream. Callers that
    /// observe `failure` after the stream ends map it to an HTTP error or
    /// an SSE error frame instead of an empty success.
    func fail(_ message: String) {
        lock.lock()
        if failureMessage == nil { failureMessage = message }
        lock.unlock()
        finish()
    }

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failureMessage
    }

    // MARK: - Usage accounting

    private var outputTokenCount = 0
    private var inputTokenEstimate = 0

    /// Called once per streamed piece from the model.
    func noteOutputToken() {
        lock.lock()
        outputTokenCount += 1
        lock.unlock()
    }

    /// Overwrites both counts when the runtime reports tokenizer-exact usage.
    func setUsage(input: Int, output: Int) {
        lock.lock()
        inputTokenEstimate = input
        outputTokenCount = output
        lock.unlock()
    }

    /// Final (input, output) token counts for response `usage` fields.
    var usage: (input: Int, output: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (inputTokenEstimate, outputTokenCount)
    }

    func finish() {
        lock.lock()
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.finish()
    }
}

@MainActor
final class LocalAPIManager: ObservableObject {
    static let shared = LocalAPIManager()

    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var addresses: [String] = []
    @Published private(set) var apiKey = LocalAPIKeyStore.key()

    private let server = LocalAPIServer()
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.mesutcydev.ioslocalllm.local-api-network")

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAddresses()
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func start() async {
        guard state == .stopped || isFailed else { return }
        guard let port = LocalAPIValidation.validPort(AppSettings.shared.localAPIPort) else {
            state = .failed("Port must be between 1024 and 65535.")
            return
        }
        updateIdleTimer(running: true)
        state = .starting
        addresses = Self.localIPv4Addresses()
        await server.setEventHandler { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .ready: self.state = .running(port: port)
                case .failed(let message):
                    self.state = .failed(message)
                    self.updateIdleTimer(running: false)
                }
            }
        }
        do {
            try await server.start(port: port)
        } catch {
            state = .failed(error.localizedDescription)
            updateIdleTimer(running: false)
        }
    }

    func stop() async {
        await server.stop()
        state = .stopped
        updateIdleTimer(running: false)
    }

    func restart() async {
        await stop()
        await start()
    }

    func refreshIdleTimerPolicy() {
        switch state {
        case .starting, .running:
            updateIdleTimer(running: true)
        case .stopped, .failed:
            updateIdleTimer(running: false)
        }
    }

    func rotateKey() {
        apiKey = LocalAPIKeyStore.rotate()
    }

    func refreshAddresses() {
        addresses = Self.localIPv4Addresses()
    }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    static func localIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }
        var results = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            let name = String(cString: interface.pointee.ifa_name)
            guard flags & IFF_UP != 0,
                  flags & IFF_LOOPBACK == 0,
                  LocalAPIValidation.isReachableLANInterface(name),
                  interface.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.pointee.ifa_addr,
                socklen_t(interface.pointee.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            if result == 0 { results.insert(String(cString: host)) }
        }
        return results.sorted()
    }

    private func updateIdleTimer(running: Bool) {
        UIApplication.shared.isIdleTimerDisabled =
            running && AppSettings.shared.localAPIKeepScreenAwake
    }
}
