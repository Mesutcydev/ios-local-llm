import Foundation

// MARK: - ReasoningCompletionGuard
//
// Thinking models can spend the entire output budget inside an open
// `<think>...</think>` block. When that happens the UI shows a reasoning
// panel but no answer. This small helper detects that completed-but-open
// state and builds the recovery prompt used by the chat view.

enum ReasoningCompletionGuard {
    static let recoveryPrompt = """
    Your previous response ended inside a reasoning block before giving the final answer. Do not continue or reveal hidden reasoning. Provide the final answer only, concise but complete.
    """

    static func needsFinalAnswerRecovery(_ text: String) -> Bool {
        guard hasUnclosedThinkBlock(text) else { return false }
        return visibleTextOutsideThinking(in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func closeForDisplay(_ text: String) -> String {
        guard hasUnclosedThinkBlock(text) else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + "\n</think>"
    }

    private static func hasUnclosedThinkBlock(_ text: String) -> Bool {
        guard let lastOpen = text.range(of: "<think>", options: [.backwards]) else {
            return false
        }
        guard let lastClose = text.range(of: "</think>", options: [.backwards]) else {
            return true
        }
        return lastClose.lowerBound < lastOpen.lowerBound
    }

    private static func visibleTextOutsideThinking(in text: String) -> String {
        var visible = ""
        var remaining = text
        while !remaining.isEmpty {
            guard let open = remaining.range(of: "<think>") else {
                visible += remaining
                break
            }
            visible += String(remaining[..<open.lowerBound])
            let afterOpen = String(remaining[open.upperBound...])
            guard let close = afterOpen.range(of: "</think>") else { break }
            remaining = String(afterOpen[close.upperBound...])
        }
        return visible
    }
}
