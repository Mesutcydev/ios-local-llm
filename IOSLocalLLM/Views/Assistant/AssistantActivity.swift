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
}
