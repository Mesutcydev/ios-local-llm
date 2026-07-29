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
    /// Template format identifier: "chatml", "qwen35", "llama3", "gemma", "phi", "custom"
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

    /// Detect the best template for a model based on its repo ID or display name.
    static func detect(for repoID: String) -> ChatTemplate {
        let lower = repoID.lowercased()
        if lower.contains("qwen3.5") || lower.contains("qwen3_5")
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
    func format(messages: [ChatMessage], enableThinking: Bool = false) -> String {
        var parts: [String] = []

        for msg in messages {
            switch msg.role {
            case .system:
                if !systemPrefix.isEmpty {
                    parts.append("\(systemPrefix)\(msg.contentForModel)\(systemSuffix)")
                } else {
                    // Some templates (Gemma) don't have system messages
                    // — inject system content into the first user turn.
                    // This is handled by the caller; here we just append.
                    parts.append("\(userPrefix)System: \(msg.contentForModel)\n\n\(msg.contentForModel)\(userSuffix)")
                }
            case .user:
                parts.append("\(userPrefix)\(msg.contentForModel)\(userSuffix)")
            case .assistant:
                // Do not feed a converted model's prompt-boundary leak back
                // into the next turn, where it tends to be imitated.
                let content = AssistantOutputSanitizer.clean(msg.contentForModel)
                parts.append("\(assistantPrefix)\(content)\(assistantSuffix)")
            case .tool:
                parts.append("\(userPrefix)Tool result:\n\(msg.contentForModel)\(userSuffix)")
            }
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
}

// MARK: - ChatMessage template extension

extension [ChatMessage] {
    /// Format messages using a specific chat template.
    func formattedWithTemplate(_ template: ChatTemplate, enableThinking: Bool = false) -> String {
        template.format(messages: self, enableThinking: enableThinking)
    }
}
