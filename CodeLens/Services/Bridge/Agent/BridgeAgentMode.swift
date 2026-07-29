import Foundation

// MARK: - BridgeAgentMode
//
// User-message pre-processor: when the typed message starts with
// `/mac`, we treat it as a request to ground the answer in the paired
// Mac's current desktop state. We synchronously detect the prefix in
// `sendMessage`/`sendOffline`, then asynchronously fetch Mac context
// via `BridgeAgentClient` and prepend it to the LLM-bound user turn.
//
// Why a prefix and not a setting:
//   Less surface area + opt-in per message. The user types `/mac`
//   when they want Xcode-aware grounding ("what error is on screen?")
//   and leaves it off otherwise. No new toggle in Settings. No
//   ambient surveillance of the Mac.
//
// Failure mode:
//   Quiet. If the Mac is unreachable, the bearer is missing, or any
//   tool errors, we drop the preamble and send the user's prompt
//   unmodified (minus the `/mac` prefix). The user sees a hint in the
//   bubble's bottom annotation that Mac context was unavailable,
//   but generation still proceeds — Phase-1 design goal of "agent
//   never blocks the chat".

@MainActor
final class BridgeAgentMode {

    static let shared = BridgeAgentMode()

    private init() {}

    /// Prefix tokens we recognise as "fetch Mac context first". `/mac`
    /// is the canonical form; `/m` is a power-user short. Whitespace-
    /// or end-of-string-terminated so we don't match `/macros`.
    private static let commandPrefixes = ["/mac ", "/mac", "/m ", "/m"]

    func isMacCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.commandPrefixes.contains { trimmed == $0 || trimmed.hasPrefix($0 + " ") || trimmed.hasPrefix($0) }
    }

    /// Strip the leading `/mac` prefix from a user message, returning
    /// the bare prompt the LLM should actually see. Trims leftover
    /// whitespace.
    func stripCommand(from text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in Self.commandPrefixes {
            if t.hasPrefix(prefix) {
                t = String(t.dropFirst(prefix.count))
                break
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build a "[Mac context: …]" preamble block by calling the
    /// Mac's read-only tools. Empty string on any failure — caller
    /// decides whether to bail or proceed without context.
    func fetchContextPreamble() async -> String {
        let client = BridgeAgentClient.shared
        async let ctxFuture       = (try? client.activeContext())
        async let workspaceFuture = (try? client.callTool(
            "project.get_workspace",
            arguments: .object([:]),
            reason:    "/mac prefix"
        ))
        let ctx       = await ctxFuture
        let workspace = await workspaceFuture
        var lines: [String] = []
        if let ctx {
            if let app = ctx.frontmostApp, !app.isEmpty {
                lines.append("frontmost: \(app)")
            }
            if let title = ctx.windowTitle, !title.isEmpty {
                lines.append("window: \(title)")
            }
            if let sel = ctx.selectedText, !sel.isEmpty {
                lines.append("selected:\n\(sel)")
            }
        }
        if let workspace, let path = workspace.stringField("path"), !path.isEmpty {
            lines.append("workspace: \(path)")
        }
        guard !lines.isEmpty else { return "" }
        return "[Mac context]\n" + lines.joined(separator: "\n") + "\n[/Mac context]"
    }

    /// Convenience: given the assistant's pre-built LLM message list
    /// and the user's original `/mac …` text, return a new list with
    /// the last user turn rewritten as `<preamble>\n\n<stripped text>`.
    /// Returns the original list untouched on failure.
    func augmented(
        messages: [ChatMessage],
        userText: String
    ) async -> [ChatMessage] {
        let preamble = await fetchContextPreamble()
        let stripped = stripCommand(from: userText)
        // Even with no preamble, strip the `/mac` so the model
        // doesn't see the literal token. Saves it from generating
        // "what does /mac mean?" replies when the Mac is offline.
        let llmText = preamble.isEmpty ? stripped : "\(preamble)\n\n\(stripped)"
        var copy = messages
        if let idx = copy.lastIndex(where: { $0.role == .user }) {
            copy[idx].content = llmText
        }
        return copy
    }
}
