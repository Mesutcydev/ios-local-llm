import Foundation

// MARK: - Assistant output cleanup

/// Removes small prompt-boundary artifacts emitted by some converted local
/// models. Keep this deliberately narrow: normal answer text must pass through
/// unchanged.
enum AssistantOutputSanitizer {
    static func clean(_ output: String) -> String {
        var lines = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowered = trimmed.lowercased()
            return lowered == "assistant: off."
                || lowered == "assistant: off"
        }

        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        if lines.first?.trimmingCharacters(in: .whitespaces) == "." {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Foundation's full Markdown parser treats a single newline as a soft
    /// break and may collapse it without leaving visible separation. Local
    /// models frequently use single newlines for compact lists, so promote
    /// those boundaries to Markdown hard breaks while leaving blank-line
    /// paragraph boundaries unchanged.
    static func preservingLineBreaksForMarkdown(_ output: String) -> String {
        let repaired = repairingRunTogetherBoundaries(in: output)
        let lines = repaired
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard lines.count > 1 else { return repaired }

        var result = ""
        for index in lines.indices {
            let line = lines[index]
            result += line
            guard index < lines.index(before: lines.endIndex) else { continue }

            let next = lines[lines.index(after: index)]
            if !line.isEmpty, !next.isEmpty, !line.hasSuffix("  ") {
                result += "  "
            }
            result += "\n"
        }
        return result
    }

    /// Some small converted models omit whitespace at semantic boundaries
    /// even though their token stream looked acceptable while arriving.
    /// Repair only strong prose signals here; fenced code is separated before
    /// this formatter is called, so identifiers and source code stay intact.
    private static func repairingRunTogetherBoundaries(in output: String) -> String {
        var repaired = output
        let replacements: [(String, String)] = [
            (#"([.!?])([A-Z])"#, "$1\n\n$2"),
            (#"([.!?])([—–]{1,3})([A-Z])"#, "$1\n\n—$3"),
            (#":([A-Z])"#, ":\n$1"),
            (#"\)([A-Z])"#, ")\n$1"),
            (
                #"([a-z0-9])((?:Any|Approximate|Based|Calculations|Chip|City|Current|Description|Document|Draft|Elements|Email|Find|Help|Important|Instagram|It|Just|Keep|Key|Let|Memory|Model|Navigation|North|Note|Once|Or|Original|Please|Pricing|Product|Prompt|Provide|Purpose|Removals|Searching|Set|Something|Step|Stock|Storage|Submit|Temperature|The|This|Uses|Visible|Website|West|What|Working|Works|Would|You|Your)\b)"#,
                "$1\n$2"
            ),
            (
                #"([A-Z]{2,})(?=(?:Chip|Description|Elements|Memory|Model|Navigation|Note|Pricing|Product|Stock|Storage|Visible|Website)\b)"#,
                "$1\n"
            ),
        ]
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(repaired.startIndex..., in: repaired)
            repaired = regex.stringByReplacingMatches(
                in: repaired,
                range: range,
                withTemplate: template
            )
        }
        return repaired
    }
}

// MARK: - Assistant Markdown blocks

/// One block of a rendered assistant answer.
struct AssistantMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case header(Int)
        case listItem(ordered: Bool, ordinal: Int, depth: Int)
        case quote
        case code
    }

    var kind: Kind
    var text: AttributedString
}

/// SwiftUI's `Text` shows inline styling (bold, italic, code, links) but
/// ignores Markdown block structure: headings, paragraphs and list items all
/// lose their line breaks and run together ("Trench WarfareWhat it was").
/// Parse once with Foundation's full Markdown, then split the result into
/// blocks by presentation intent so the view can lay each one out itself.
enum AssistantMarkdownBlocks {
    static func parse(_ source: String) -> [AssistantMarkdownBlock] {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            return [AssistantMarkdownBlock(kind: .paragraph, text: AttributedString(source))]
        }

        struct Pending {
            var key: [Int]
            var block: AssistantMarkdownBlock
            var cell: Int?
        }
        var pending: [Pending] = []

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            var piece = AttributedString(attributed[run.range])
            piece.presentationIntent = nil

            var header: Int?
            var ordinal: Int?
            var itemIsOrdered: Bool?
            var listDepth = 0
            var isQuote = false
            var isCode = false
            var cell: Int?
            var rowIdentity: Int?
            for component in components {
                switch component.kind {
                case .header(let level): header = level
                case .listItem(let value):
                    if ordinal == nil { ordinal = value }   // innermost item wins
                case .orderedList, .unorderedList:
                    listDepth += 1
                    if ordinal != nil, itemIsOrdered == nil {
                        if case .orderedList = component.kind { itemIsOrdered = true } else { itemIsOrdered = false }
                    }
                case .blockQuote: isQuote = true
                case .codeBlock: isCode = true
                case .tableCell(let column): cell = column
                case .tableRow, .tableHeaderRow: rowIdentity = component.identity
                default: break
                }
            }

            let kind: AssistantMarkdownBlock.Kind
            if let header {
                kind = .header(header)
            } else if let ordinal {
                kind = .listItem(ordered: itemIsOrdered ?? false, ordinal: ordinal, depth: max(listDepth, 1))
            } else if isCode {
                kind = .code
            } else if isQuote {
                kind = .quote
            } else {
                kind = .paragraph
            }

            // A table row becomes one line with its cells separated by " | ".
            let key = rowIdentity.map { [$0] } ?? (components.isEmpty ? [-1] : components.map(\.identity))
            if let last = pending.indices.last, pending[last].key == key {
                if let cell, let previous = pending[last].cell, cell != previous {
                    pending[last].block.text += AttributedString("  |  ")
                }
                pending[last].block.text += piece
                pending[last].cell = cell ?? pending[last].cell
            } else {
                pending.append(Pending(key: key, block: AssistantMarkdownBlock(kind: kind, text: piece), cell: cell))
            }
        }
        return pending.map(\.block)
    }
}

// MARK: - Image grounding handoff cleanup

/// Cleans text produced by one local model before it is embedded inside
/// another model's chat template. Vision runtimes can occasionally surface
/// their own role/end tokens as ordinary text; passing those through verbatim
/// can close the receiving model's user turn and make it emit EOS immediately.
enum ImageGroundingSanitizer {
    static func clean(_ output: String) -> String {
        var cleaned = output
            .replacingOccurrences(of: "\r\n", with: "\n")

        let controlPatterns = [
            #"<\|[^>\n]{1,80}\|>"#,
            #"</?s>"#,
            #"<end_of_(?:utterance|turn)>"#,
            #"\[/?INST\]"#,
            #"<<\/?SYS>>"#,
        ]
        for pattern in controlPatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*(?:assistant|system|user)\s*:?\s*$\n?"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"(?im)^\s*(?:assistant|system|user)\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"[ \t]+\n"#,
            with: "\n",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - ChatTemplate
// Describes the prompt formatting rules for a specific model family.
// Used to properly format conversation history before tokenization.
// Different model families (Qwen, Llama, Gemma, Phi) use different
// control tokens and formatting conventions.

struct ChatTemplate: Codable, Hashable {
    /// Template format identifier: "chatml", "qwen35", "lfm3", "lfm3_audio", "llama3", "gemma", "phi", "custom"
    let format: String
    /// Opening tag for a system message turn (e.g. "<|im_start|>system\n")
    let systemPrefix: String
    /// Closing tag for a system message (e.g. "<|im_end|>")
    let systemSuffix: String
    /// Opening tag for a user message turn
    let userPrefix: String
    let userSuffix: String
    /// Opening tag for the assistant message turn
    let assistantPrefix: String
    let assistantSuffix: String
    /// The prompt suffix that tells the model to start generating
    /// (e.g. "<|im_start|>assistant\n" for ChatML)
    let generationPrompt: String
    /// Whether the model supports a "thinking" mode toggle
    let supportsThinking: Bool
    /// Optional tag to suppress thinking (e.g. "/no_think" for Qwen3)
    let noThinkTag: String?
    /// Optional tag to enable thinking (e.g. "/think" for Qwen3)
    let thinkTag: String?
    /// Extra end-of-sequence tokens beyond the standard ones
    let extraEOSTokens: [String]

    // MARK: - Built-in templates

    /// ChatML — used by Qwen2.5, Qwen3, and many Chinese models.
    static let chatML = ChatTemplate(
        format: "chatml",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: true,
        noThinkTag: " /no_think",
        thinkTag: " /think",
        extraEOSTokens: ["<|im_end|>"]
    )

    /// Qwen 3.5 hybrid-attention models use ChatML turns but start every
    /// assistant response with an explicit thinking block. Bonsai 27B keeps
    /// this tokenizer contract even though its repository name omits Qwen.
    static let qwen35 = ChatTemplate(
        format: "qwen35",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: true,
        noThinkTag: "<think>\n\n</think>\n\n",
        thinkTag: "<think>\n",
        extraEOSTokens: ["<|im_end|>"]
    )

    /// Llama 3 — uses <|begin_of_text|> and <|eot_id|>
    static let llama3 = ChatTemplate(
        format: "llama3",
        systemPrefix: "<|start_header_id|>system<|end_header_id|>\n\n",
        systemSuffix: "<|eot_id|>",
        userPrefix: "<|start_header_id|>user<|end_header_id|>\n\n",
        userSuffix: "<|eot_id|>",
        assistantPrefix: "<|start_header_id|>assistant<|end_header_id|>\n\n",
        assistantSuffix: "<|eot_id|>",
        generationPrompt: "<|start_header_id|>assistant<|end_header_id|>\n\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|eot_id|>"]
    )

    /// Gemma — uses <bos>, user/nmodel turns
    static let gemma = ChatTemplate(
        format: "gemma",
        systemPrefix: "",
        systemSuffix: "",
        userPrefix: "<start_of_turn>user\n",
        userSuffix: "<end_of_turn>\n",
        assistantPrefix: "<start_of_turn>model\n",
        assistantSuffix: "<end_of_turn>\n",
        generationPrompt: "<start_of_turn>model\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<end_of_turn>"]
    )

    /// Phi — uses <|user|>, <|assistant|>, <|system|>
    static let phi = ChatTemplate(
        format: "phi",
        systemPrefix: "<|system|>\n",
        systemSuffix: "<|end|>\n",
        userPrefix: "<|user|>\n",
        userSuffix: "<|end|>\n",
        assistantPrefix: "<|assistant|>\n",
        assistantSuffix: "<|end|>\n",
        generationPrompt: "<|assistant|>\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|end|>", "<|endoftext|>"]
    )

    /// Generic / unknown — fallback to ChatML which is the most widely used.
    static let generic = ChatTemplate(
        format: "generic",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: false,
        noThinkTag: nil,
        thinkTag: nil,
        extraEOSTokens: ["<|im_end|>"]
    )

    // MARK: - Resolution

    /// LFM3 uses ChatML with an explicit reasoning prefix, not Qwen's
    /// /think commands. The official GGUF disables automatic BOS insertion.
    static let lfm3 = ChatTemplate(
        format: "lfm3",
        systemPrefix: "<|im_start|>system\n",
        systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n",
        userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n",
        assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n",
        supportsThinking: true,
        noThinkTag: "<think></think>",
        thinkTag: "<think>",
        extraEOSTokens: ["<|im_end|>"]
    )

    /// The shipped LFM3-Audio checkpoint's default template ends the turn with
    /// a bare assistant cue and carries no reasoning tag at all.
    static let lfm3Audio = ChatTemplate(
        format: "lfm3_audio",
        systemPrefix: "<|im_start|>system\n", systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n", userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n", assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n", supportsThinking: false,
        noThinkTag: nil, thinkTag: nil, extraEOSTokens: ["<|im_end|>"]
    )

    /// Omni keeps the text checkpoint's non-reasoning cue even though it is
    /// driven through the Audio pipeline. It is never offered as thinking.
    static let lfm3Omni = ChatTemplate(
        format: "lfm3_omni",
        systemPrefix: "<|im_start|>system\n", systemSuffix: "<|im_end|>\n",
        userPrefix: "<|im_start|>user\n", userSuffix: "<|im_end|>\n",
        assistantPrefix: "<|im_start|>assistant\n", assistantSuffix: "<|im_end|>\n",
        generationPrompt: "<|im_start|>assistant\n<think></think>", supportsThinking: false,
        noThinkTag: nil, thinkTag: nil, extraEOSTokens: ["<|im_end|>"]
    )

    /// Detect the best template for a model based on its repo ID or display name.
    static func detect(for repoID: String) -> ChatTemplate {
        let lower = repoID.lowercased()
        if lower.contains("lfm3-audio") { return .lfm3Audio }
        if lower.contains("lfm3-omni") { return .lfm3Omni }
        if lower.contains("lfm3") { return .lfm3 }
        if lower.contains("qwen3.5") || lower.contains("qwen3_5")
            || lower.contains("ornith")
            || (lower.contains("bonsai") && lower.contains("27b")) {
            return .qwen35
        }
        if lower.contains("bonsai") { return .chatML }
        if lower.contains("qwen")   { return .chatML }
        if lower.contains("llama")  { return .llama3 }
        if lower.contains("gemma")  { return .gemma }
        if lower.contains("phi")    { return .phi }
        if lower.contains("smol")   { return .chatML }
        return .generic
    }

    // MARK: - Formatting

    /// Format an array of ChatMessage into the model's prompt format.
    func format(
        messages: [ChatMessage],
        enableThinking: Bool = false,
        leaveLastAssistantOpen: Bool = false
    ) -> String {
        let isLFM3 = format.hasPrefix("lfm3")
        var parts: [String] = isLFM3 ? ["<|startoftext|>"] : []
        var pendingSystem: [String] = []

        func flushPendingSystem(into userContent: String) -> String {
            guard !pendingSystem.isEmpty else { return userContent }
            let system = pendingSystem.joined(separator: "\n\n")
            pendingSystem.removeAll()
            let trimmedUser = userContent.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedUser.isEmpty ? system : system + "\n\n" + userContent
        }

        func emitUserTurn(_ content: String) {
            parts.append("\(userPrefix)\(content)\(userSuffix)")
        }

        // LFM3 renders tool results as tool turns, so they are not the user's turn.
        func isLFM3ToolResult(_ msg: ChatMessage) -> Bool {
            isLFM3 && msg.role == .user && (msg.contentForModel.hasPrefix("[Tool result")
                || msg.contentForModel.hasPrefix("```tool_result")
                || msg.contentForModel.hasPrefix("TOOL RESULT:"))
        }

        // Chat drops the model's call turn from the transcript and keeps the
        // call on its result; replay it so LFM3 sees call → response, as trained.
        func emitLFM3ToolResponse(_ msg: ChatMessage, at index: Int) {
            if index == 0 || messages[index - 1].role != .assistant,
               let json = msg.toolCallJSON, let call = LFM3ToolCodec.nativeCall(json: json) {
                let cue = self.format == "lfm3_audio" ? "" : "<think></think>"
                parts.append("\(assistantPrefix)\(cue)\(call)\(assistantSuffix)")
            }
            parts.append("<|im_start|>tool\n<tool_response>\n\(msg.contentForModel)\n</tool_response><|im_end|>\n")
        }

        let lastIndex = messages.indices.last
        let lastUserIndex = messages.lastIndex(where: { $0.role == .user && !isLFM3ToolResult($0) })
        let openLastAssistant = leaveLastAssistantOpen && messages.last?.role == .assistant

        for (index, msg) in messages.enumerated() {
            switch msg.role {
            case .system:
                if !systemPrefix.isEmpty {
                    let content = isLFM3 ? msg.contentForModel.replacingOccurrences(
                        of: ToolRunner.systemPromptAddendum,
                        with: LFM3ToolCodec.instructions(tools: LFM3ToolCodec.localTools)
                    ) : msg.contentForModel
                    parts.append("\(systemPrefix)\(content)\(systemSuffix)")
                } else {
                    // Gemma (and other templates without a system role) fold
                    // instructions into the next user turn once. The previous
                    // path emitted `System: X\n\nX` as its own user turn,
                    // which duplicated a long prompt and made small models
                    // imitate or invent the instructions.
                    pendingSystem.append(msg.contentForModel)
                }
            case .user:
                if isLFM3ToolResult(msg) {
                    emitLFM3ToolResponse(msg, at: index)
                } else {
                    emitUserTurn(flushPendingSystem(into: msg.contentForModel))
                }
            case .assistant:
                if !pendingSystem.isEmpty {
                    emitUserTurn(flushPendingSystem(into: ""))
                }
                let rawContent = isLFM3 ? LFM3ToolCodec.historyContent(msg.contentForModel) : AssistantOutputSanitizer.clean(msg.contentForModel)
                // LFM3's text and Omni templates give every assistant turn a
                // reasoning cue; Audio's template has none.
                let content: String
                if isLFM3, format != "lfm3_audio" {
                    content = Self.lfm3HistoryContent(
                        rawContent,
                        beforeLatestUser: lastUserIndex.map { index < $0 } ?? false,
                        openReasoning: openLastAssistant && index == lastIndex
                            && supportsThinking && enableThinking
                    )
                } else {
                    content = rawContent
                }
                if openLastAssistant && index == lastIndex {
                    parts.append("\(assistantPrefix)\(content)")
                } else {
                    parts.append("\(assistantPrefix)\(content)\(assistantSuffix)")
                }
            case .tool:
                if isLFM3 {
                    emitLFM3ToolResponse(msg, at: index)
                } else {
                    emitUserTurn(flushPendingSystem(into: "Tool result:\n\(msg.contentForModel)"))
                }
            }
        }
        if !pendingSystem.isEmpty {
            emitUserTurn(flushPendingSystem(into: ""))
        }

        if openLastAssistant {
            return parts.joined()
        }

        // Build the generation prompt — the model responds after this.
        var prompt = generationPrompt
        if supportsThinking && enableThinking, let tag = thinkTag {
            prompt += tag
        } else if supportsThinking && !enableThinking, let tag = noThinkTag {
            prompt += tag
        }
        parts.append(prompt)

        return parts.joined()
    }

    /// Matches the released LFM3 template's assistant replay. Turns before the
    /// latest user turn drop stored reasoning behind `<think></think>`. Later
    /// turns (tool-call steps, the continuation target) keep their reasoning,
    /// restoring the `<think>` the prompt prefilled; a turn without reasoning
    /// gets the cue it was generated after.
    private static func lfm3HistoryContent(_ content: String, beforeLatestUser: Bool, openReasoning: Bool) -> String {
        if let end = content.range(of: "</think>", options: .backwards) {
            if beforeLatestUser {
                return "<think></think>" + content[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return content.hasPrefix("<think>") ? content : "<think>" + content
        }
        return (openReasoning ? "<think>" : "<think></think>") + content
    }
}

// MARK: - ChatMessage template extension

extension [ChatMessage] {
    /// Format messages using a specific chat template.
    func formattedWithTemplate(
        _ template: ChatTemplate,
        enableThinking: Bool = false,
        leaveLastAssistantOpen: Bool = false
    ) -> String {
        template.format(
            messages: self,
            enableThinking: enableThinking,
            leaveLastAssistantOpen: leaveLastAssistantOpen
        )
    }
}

// Native LFM3 XML-style calls are not XML documents: `<function=name>` and
// `<parameter=name>` are model delimiters. Parse only complete, bounded calls.
enum LFM3ToolCodec {
    struct Call {
        let name: String
        let arguments: [String: Any]
    }

    /// The API decoder's stable text history remains unchanged for other
    /// models. Reconstruct native assistant calls only while formatting LFM3.
    static func historyContent(_ content: String) -> String {
        guard content.contains("[Previous tool calls]"),
              let regex = try? NSRegularExpression(pattern: #"(?m)^call_id=\S+ name=([A-Za-z_][A-Za-z0-9_.-]*) arguments=(\{.*\})$"#) else { return AssistantOutputSanitizer.clean(content) }
        var result = content
        for match in regex.matches(in: content, range: NSRange(content.startIndex..., in: content)).reversed() {
            guard let range = Range(match.range, in: content),
                  let nameRange = Range(match.range(at: 1), in: content),
                  let argsRange = Range(match.range(at: 2), in: content),
                  let args = (try? JSONSerialization.jsonObject(with: Data(content[argsRange].utf8))) as? [String: Any] else { continue }
            result.replaceSubrange(range, with: nativeCall(name: String(content[nameRange]), arguments: args))
        }
        return result.replacingOccurrences(of: "[Previous tool calls]\n", with: "")
    }

    /// One call in the released template's `render_tool_calls` form.
    static func nativeCall(name: String, arguments: [String: Any]) -> String {
        let parameters = arguments.keys.sorted().compactMap { key -> String? in
            let value: String
            if let text = arguments[key] as? String { value = text }
            else if let argument = arguments[key], let data = try? JSONSerialization.data(withJSONObject: argument, options: [.fragmentsAllowed, .sortedKeys]) {
                value = String(decoding: data, as: UTF8.self)
            } else { return nil }
            return "<parameter=\(key)>\n\(value)\n</parameter>\n"
        }.joined()
        return "<tool_call>\n<function=\(name)>\n\(parameters)</function>\n</tool_call>"
    }

    /// Replays a `ChatMessage.toolCallJSON` as a native call.
    static func nativeCall(json: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        return nativeCall(name: name, arguments: object["arguments"] as? [String: Any] ?? [:])
    }

    // Descriptions carry the same guidance as `ToolRunner.systemPromptAddendum`,
    // which this catalog replaces for LFM3; without them the model sees bare
    // names and calls `file_read` or `index_document` at random.
    static let localTools: [LocalAPIToolDefinition] = [
        definition("calculator", "Evaluate an arithmetic expression.", ["expression": "string"], required: ["expression"]),
        definition("datetime", "Current date and time, optionally in an IANA timezone.", ["timezone": "string"]),
        definition("unit_convert", "Convert a value between basic SI and imperial units.", ["value": "number", "from": "string", "to": "string"], required: ["value", "from", "to"]),
        definition("web_search", "Search the web, or fetch a page when query is an http(s) URL. Returns extracted text to quote. Only for current events, live data or facts you do not know. Never for writing code, HTML, websites or text you can write yourself.", ["query": "string"], required: ["query"]),
        definition("file_read", "Ask the user to pick local files and return their text. Only when the request needs a file they have not attached.", ["prompt": "string"]),
        definition("describe_image", "Describe the most recently attached image with the local vision model.", ["prompt": "string"]),
        definition("knowledge_base", "Search the user's own indexed documents. Use for questions about their files.", ["query": "string"], required: ["query"]),
        definition("index_document", "Save text to the user's Knowledge Base when they ask you to remember a snippet or document.", ["text": "string", "name": "string"], required: ["text"]),
        definition("calendar_events", "List the user's upcoming calendar events (default 7 days, max 30). Only when they ask about their schedule. The user is asked first.", ["days": "number"]),
        definition("add_event", "Add a calendar event. start and end are ISO 8601 local time such as 2026-11-14T15:00; end defaults to one hour. The user is asked first.", ["title": "string", "start": "string", "end": "string", "notes": "string"], required: ["title", "start"]),
        definition("add_reminder", "Add a reminder, optionally due at an ISO 8601 local time such as 2026-11-14T15:00. The user is asked first.", ["title": "string", "due": "string", "notes": "string"], required: ["title"]),
        definition("generate_image", "Generate an image on-device with the downloaded diffusion model. Only when the user asks for a picture, photo or drawing. Never for code, HTML or animations.", ["prompt": "string", "model": "string"], required: ["prompt"]),
    ]

    private static func definition(_ name: String, _ description: String, _ fields: [String: String], required: [String] = []) -> LocalAPIToolDefinition {
        let schema: [String: Any] = ["type": "object", "properties": fields.mapValues { ["type": $0] }, "required": required]
        let data = try! JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        return .init(name: name, description: description, parametersJSON: String(decoding: data, as: UTF8.self))
    }

    static func instructions(tools: [LocalAPIToolDefinition]) -> String {
        // The released template renders one unwrapped function per line as
        // `{"name": …, "description": …, "parameters": …}` (key order and
        // separators from its `tool_to_json`). Match that training format.
        let lines = tools.compactMap { tool -> String? in
            guard let data = tool.parametersJSON.data(using: .utf8),
                  let parameters = try? JSONSerialization.jsonObject(with: data),
                  let parametersJSON = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let name = try? JSONSerialization.data(withJSONObject: tool.name, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                  let description = try? JSONSerialization.data(withJSONObject: tool.description ?? "", options: [.fragmentsAllowed, .withoutEscapingSlashes])
            else { return nil }
            return "{\"name\": \(String(decoding: name, as: UTF8.self)), "
                + "\"description\": \(String(decoding: description, as: UTF8.self)), "
                + "\"parameters\": \(String(decoding: parametersJSON, as: UTF8.self))}"
        }.joined(separator: "\n")
        return """
        You have access to the following functions. Use them only when needed. Use the exact function and parameter names in their schemas. Never invent results; wait for a tool response. Ordinary answers need no tool call. Never claim you searched the web, read a file, looked at an image, or generated an image without its tool response.
        <tools>
        \(lines)
        </tools>
        Emit function calls in the native tool_call format, then stop. Object and array parameter values must be valid JSON. Do not call unavailable functions.
        """
    }

    static func parse(_ output: String, tools: [LocalAPIToolDefinition]) -> [Call] {
        guard output.utf8.count <= 1_048_576 else { return [] }
        // Reasoning is never executable. Wait for a complete closing tag.
        let text: String
        if let end = output.range(of: "</think>", options: .backwards) {
            text = String(output[end.upperBound...])
        } else if output.contains("<think>") {
            return []
        } else {
            text = output
        }
        let definitions = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard let regex = try? NSRegularExpression(pattern: #"<tool_call>\s*<function=([A-Za-z_][A-Za-z0-9_.-]*)>([\s\S]*?)</function>\s*</tool_call>"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(64).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text),
                  let definition = definitions[String(text[nameRange])],
                  let schemaData = definition.parametersJSON.data(using: .utf8),
                  let schema = (try? JSONSerialization.jsonObject(with: schemaData)) as? [String: Any],
                  let arguments = parameters(String(text[bodyRange]), schema: schema) else { return nil }
            return Call(name: definition.name, arguments: arguments)
        }
    }

    private static func parameters(_ body: String, schema: [String: Any]) -> [String: Any]? {
        let fields = schema["properties"] as? [String: [String: Any]] ?? [:]
        var remaining = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String: Any] = [:]
        while !remaining.isEmpty {
            guard result.count < 128, remaining.hasPrefix("<parameter="),
                  let nameEnd = remaining.firstIndex(of: ">"),
                  let valueEnd = remaining.range(of: "</parameter>") else { return nil }
            let name = String(remaining[remaining.index(remaining.startIndex, offsetBy: 11)..<nameEnd])
            guard result[name] == nil, let field = fields[name] else { return nil }
            var raw = String(remaining[remaining.index(after: nameEnd)..<valueEnd.lowerBound])
            if raw.hasPrefix("\n") { raw.removeFirst() }
            if raw.hasSuffix("\n") { raw.removeLast() }
            guard !raw.contains("<parameter="), !raw.contains("<function="), !raw.contains("<tool_call>") else { return nil }
            let type = field["type"] as? String
            let decoded = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            let value: Any = type == "string" ? raw : decoded ?? raw
            guard valid(value, schema: field) else { return nil }
            result[name] = value
            remaining = String(remaining[valueEnd.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard (schema["required"] as? [String] ?? []).allSatisfy({ result[$0] != nil }) else { return nil }
        return result
    }

    private static func valid(_ value: Any, schema: [String: Any]) -> Bool {
        if let allowed = schema["enum"] as? [Any], !allowed.contains(where: { String(describing: $0) == String(describing: value) }) { return false }
        guard let type = schema["type"] as? String else { return true }
        switch type {
        case "string": return value is String
        case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "number", "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return false }
            return type == "number" || number.doubleValue.rounded() == number.doubleValue
        case "array":
            guard let values = value as? [Any] else { return false }
            return values.count <= 1024 && values.allSatisfy { valid($0, schema: schema["items"] as? [String: Any] ?? [:]) }
        case "object":
            guard let values = value as? [String: Any] else { return false }
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            return (schema["required"] as? [String] ?? []).allSatisfy { values[$0] != nil }
                && values.allSatisfy { key, value in
                    if let property = properties[key] { return valid(value, schema: property) }
                    return schema["additionalProperties"] as? Bool != false
                }
        case "null": return value is NSNull
        default: return false
        }
    }
}
