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
        case .generating: return "Generating"
        case .reasoning: return "Thinking"
        case .preparingTool(let name): return "Preparing \(displayName(forTool: name))"
        case .runningTool(let name): return "Running \(displayName(forTool: name))"
        case .awaitingApproval(let name): return "Needs approval · \(displayName(forTool: name))"
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
            return firstLine.isEmpty ? "Web search finished" : String(firstLine.prefix(80))
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

    static func citationTitle(visibleCount: Int) -> String {
        visibleCount == 1 ? "Used 1 web source" : "Used \(visibleCount) web sources"
    }

    enum ImageStatus: Equatable {
        case downloading(Double)
        case loading
        case generating(Double)
        case failed(String)
    }

    static func imageGenerationSubtitle(_ status: ImageStatus) -> String {
        switch status {
        case .downloading(let p):
            return "Downloading · \(Int((p * 100).rounded()))%"
        case .loading:
            return "Loading image model"
        case .generating(let p):
            return "Generating · \(Int((p * 100).rounded()))%"
        case .failed:
            return "Image generation failed"
        }
    }
}
