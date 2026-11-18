import Foundation

/// Pure helpers for in-chat activity cards. Kept off SwiftUI so the
/// transcript can render streaming / approval / tool-result chrome without
/// changing the generate or ToolRunner loops.
enum AssistantActivity {
    enum Status: Equatable {
        case generating
        case reasoning
        case preparingTool(String)
        case runningTool(String)
        case awaitingApproval(String)
    }

    struct ToolResultPayload: Equatable {
        let name: String
        let result: String
    }

    static func streamingStatus(
        content: String,
        detectedToolName: String?
    ) -> Status {
        if let name = detectedToolName, !name.isEmpty {
            return .preparingTool(name)
        }
        if isOpenReasoning(content) {
            return .reasoning
        }
        return .generating
    }

    static func isOpenReasoning(_ content: String) -> Bool {
        let c = content
        if c.contains("<think>"), !c.contains("</think>") { return true }
        if !c.contains("<think>"), c.contains("</think>") { return false }
        return false
    }

    static func displayName(forTool name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func symbol(forTool name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("web") || lower.contains("search") { return "globe" }
        if lower.contains("file") { return "doc.text" }
        if lower.contains("vision") || lower.contains("image") { return "eye" }
        if lower.contains("memory") || lower.contains("knowledge") { return "brain.head.profile" }
        if lower.contains("calc") { return "function" }
        if lower.contains("calendar") || lower.contains("event") { return "calendar" }
        if lower.contains("reminder") { return "checklist" }
        if lower.contains("date") || lower.contains("time") { return "clock" }
        return "wrench.and.screwdriver"
    }

    static func parseToolResult(_ content: String) -> ToolResultPayload? {
        let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```tool_result") else { return nil }
        let inner = t
            .replacingOccurrences(of: "```tool_result", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = inner.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let name = (obj["name"] as? String) ?? "tool"
        let result: String = {
            if let s = obj["result"] as? String { return s }
            if let r = obj["result"] { return String(describing: r) }
            return ""
        }()
        return ToolResultPayload(name: name, result: result)
    }

    static func statusTitle(_ status: Status) -> String {
        switch status {
        case .generating: return LocalizationService.shared.t("Generating")
        case .reasoning: return LocalizationService.shared.t("Thinking")
        case .preparingTool(let name): return LocalizationService.shared.t("Preparing \(displayName(forTool: name))")
        case .runningTool(let name): return LocalizationService.shared.t("Running \(displayName(forTool: name))")
        case .awaitingApproval(let name): return LocalizationService.shared.t("Needs approval · \(displayName(forTool: name))")
        }
    }

    /// Stop means the user cancelled the turn. A late tool result may still
    /// land, but it must not start another generate.
    static func shouldFollowUpAfterTool(aborted: Bool) -> Bool {
        !aborted
    }

    static func canResumeTruncatedReply(
        hitTokenLimit: Bool?,
        isStreaming: Bool,
        wasInterrupted: Bool?
    ) -> Bool {
        hitTokenLimit == true && !isStreaming && wasInterrupted != true
    }

    static func continuationMessageIndex(in messages: [ChatMessage]) -> Int? {
        guard let idx = messages.lastIndex(where: { $0.role == .assistant }) else {
            return nil
        }
        let message = messages[idx]
        guard canResumeTruncatedReply(
            hitTokenLimit: message.hitTokenLimit,
            isStreaming: message.isStreaming,
            wasInterrupted: message.wasInterrupted
        ) else { return nil }
        return idx
    }

    enum ToolResultKind: Equatable {
        case web, file, calculator, image, datetime, knowledge, other
    }

    static func toolResultKind(name: String) -> ToolResultKind {
        let lower = name.lowercased()
        if lower.contains("web") || lower.contains("search") { return .web }
        if lower.contains("file") { return .file }
        if lower.contains("calc") { return .calculator }
        if lower.contains("image") || lower.contains("vision") { return .image }
        if lower.contains("date") || lower.contains("time") { return .datetime }
        if lower.contains("knowledge") || lower.contains("index") { return .knowledge }
        return .other
    }

    static func toolResultSummary(name: String, result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? trimmed
        switch toolResultKind(name: name) {
        case .calculator:
            return firstLine.isEmpty ? "Calculated on device" : firstLine
        case .file:
            if firstLine.isEmpty { return "Read a local file" }
            return "File · \(firstLine)"
        case .web:
            // The result is the model's WEB CONTEXT block; its first line is
            // an internal marker, so summarize the sources instead.
            let siteLines = trimmed.split(separator: "\n").filter { $0.hasPrefix("Site: ") }
            if !siteLines.isEmpty {
                var names: [String] = []
                for line in siteLines {
                    let site = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    if !site.isEmpty, !names.contains(site) { names.append(site) }
                }
                let label = siteLines.count == 1 ? "1 source" : "\(siteLines.count) sources"
                return names.isEmpty ? label : "\(label) · \(names.prefix(3).joined(separator: ", "))"
            }
            if firstLine.isEmpty || firstLine.hasPrefix("WEB CONTEXT") { return "Web search finished" }
            return String(firstLine.prefix(80))
        case .image:
            return "Image generated on device"
        case .datetime:
            return firstLine.isEmpty ? "Current time" : firstLine
        case .knowledge:
            return firstLine.isEmpty ? "Knowledge Base result" : String(firstLine.prefix(80))
        case .other:
            return firstLine.isEmpty ? "Completed on device" : String(firstLine.prefix(80))
        }
    }

    /// True once the user declined or cancelled a tool since their last
    /// message. The rest of that turn answers without tools: offered them
    /// again, small models asked for another one (a declined image, then a
    /// web search) instead of answering.
    static func userDeclinedToolThisTurn(_ messages: [ChatMessage]) -> Bool {
        for message in messages.reversed() where message.role == .user {
            guard let result = parseToolResult(message.content)?.result
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
            if result.hasPrefix("the user cancelled") || result.hasPrefix("the user declined")
                || result.hasPrefix(skippedToolResult.lowercased()) { return true }
        }
        return false
    }

    /// Tool result for a web_search or generate_image the app skipped; counts
    /// as a decline. Its card is hidden. The wording keeps small models from
    /// opening with "I don't have an image tool, but…".
    static let skippedToolResult = "Not needed for this request. Reply directly with the finished answer and do not mention tools."

    /// Streaming text up to a tool call the model is still writing. The call
    /// only parses once complete; until then its raw markup showed in the bubble.
    static func hidingToolCallMarkup(_ text: String) -> String {
        guard let start = text.range(of: #"<tool_call|```tool(?![A-Za-z0-9_])"#,
                                     options: .regularExpression) else { return text }
        return String(text[..<start.lowerBound])
    }

    /// The user's own latest message, skipping tool-result turns.
    static func latestUserRequest(_ messages: [ChatMessage]) -> String? {
        messages.last { $0.role == .user && parseToolResult($0.content) == nil }?.content
    }

    /// True for a "write / build me X" request that asks for no live data.
    /// Small models still call web_search for "write a website html"; the
    /// chat skips that search.
    /// ponytail: keyword heuristic. A miss only lets the search run, as before.
    static func isOfflineAuthoringRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.")
            || lower.contains("look up") { return false }
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        let authoring: Set<String> = ["write", "create", "build", "make", "code", "design",
                                      "draft", "implement", "compose", "generate"]
        let liveData: Set<String> = ["search", "google", "lookup", "latest", "news", "today",
                                     "tonight", "current", "currently", "recent", "price",
                                     "prices", "weather"]
        return !words.isDisjoint(with: authoring) && words.isDisjoint(with: liveData)
    }

    /// True for a code request that never asks for a picture. Small models
    /// still call generate_image for "an HTML page with a pastel background";
    /// the chat skips that image.
    /// ponytail: keyword heuristic. A miss only lets the image run, as before.
    static func isCodeRequestWithoutImage(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        let code: Set<String> = ["html", "css", "javascript", "code", "website", "webpage",
                                 "script", "swift", "python", "function", "json", "sql", "svg"]
        let picture: Set<String> = ["image", "images", "picture", "pictures", "photo", "photos",
                                    "draw", "drawing", "paint", "painting", "illustration",
                                    "sketch", "wallpaper"]
        return !words.isDisjoint(with: code) && words.isDisjoint(with: picture)
    }

    static func citationTitle(visibleCount: Int) -> String {
        visibleCount == 1 ? "Used 1 web source" : "Used \(visibleCount) web sources"
    }

    enum ImageStatus: Equatable {
        case downloading(Double)
        case loading
        case generating(Double)
        case checking
        case failed(String)
    }

    static func imageGenerationSubtitle(_ status: ImageStatus) -> String {
        switch status {
        case .downloading(let p):
            return LocalizationService.shared.t("Downloading · \(Int((p * 100).rounded()))%")
        case .loading:
            return LocalizationService.shared.t("Loading image model")
        case .generating(let p):
            return LocalizationService.shared.t("Generating · \(Int((p * 100).rounded()))%")
        case .checking:
            return LocalizationService.shared.t("Checking image locally")
        case .failed:
            return LocalizationService.shared.t("Image generation failed")
        }
    }
}
