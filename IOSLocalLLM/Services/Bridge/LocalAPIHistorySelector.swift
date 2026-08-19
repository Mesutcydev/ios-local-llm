import Foundation

struct LocalAPIHistorySelection: Equatable, Sendable {
    let messages: [ChatMessage]
    let originalPrompt: LocalAPITokenCount
    let effectivePrompt: LocalAPITokenCount
    let removedMessageCount: Int
    let removedGroupCount: Int
    let didTruncate: Bool
}

enum LocalAPIHistorySelectionError: Error, Equatable, Sendable {
    case requiredContentTooLarge(LocalAPITokenCount)
}

enum LocalAPIHistorySelector {
    typealias TokenCounter = @Sendable ([ChatMessage]) async throws -> LocalAPITokenCount

    static func select(
        messages: [ChatMessage],
        promptBudget: Int,
        counter: @escaping TokenCounter
    ) async throws -> LocalAPIHistorySelection {
        let original = try await counter(messages)
        let systemMessages = messages.filter { $0.role == .system }
        let dialog = messages.filter { $0.role != .system }
        let groups = conversationGroups(dialog)

        if original.tokens <= promptBudget {
            return LocalAPIHistorySelection(
                messages: messages,
                originalPrompt: original,
                effectivePrompt: original,
                removedMessageCount: 0,
                removedGroupCount: 0,
                didTruncate: false
            )
        }

        guard let newestGroup = groups.last else {
            let required = try await counter(systemMessages)
            guard required.tokens <= promptBudget else {
                throw LocalAPIHistorySelectionError.requiredContentTooLarge(required)
            }
            return LocalAPIHistorySelection(
                messages: systemMessages,
                originalPrompt: original,
                effectivePrompt: required,
                removedMessageCount: messages.count - systemMessages.count,
                removedGroupCount: 0,
                didTruncate: messages.count > systemMessages.count
            )
        }

        let newestMessages = newestGroup
        let requiredMessages = systemMessages + newestMessages
        let requiredCount = try await counter(requiredMessages)
        guard requiredCount.tokens <= promptBudget else {
            throw LocalAPIHistorySelectionError.requiredContentTooLarge(requiredCount)
        }

        var firstKeptGroup = groups.count - 1
        var selected = requiredMessages
        var selectedCount = requiredCount

        while firstKeptGroup > 0 {
            let candidateGroups = Array(groups[(firstKeptGroup - 1)...])
            let candidate = systemMessages + candidateGroups.flatMap { $0 }
            let candidateCount = try await counter(candidate)
            guard candidateCount.tokens <= promptBudget else { break }
            firstKeptGroup -= 1
            selected = candidate
            selectedCount = candidateCount
        }

        let removedGroups = firstKeptGroup
        let removedMessages = groups[..<firstKeptGroup].flatMap { $0 }.count
        return LocalAPIHistorySelection(
            messages: selected,
            originalPrompt: original,
            effectivePrompt: selectedCount,
            removedMessageCount: removedMessages,
            removedGroupCount: removedGroups,
            didTruncate: removedMessages > 0
        )
    }

    static func conversationGroups(_ messages: [ChatMessage]) -> [[ChatMessage]] {
        guard !messages.isEmpty else { return [] }
        var groups: [[ChatMessage]] = []
        var current: [ChatMessage] = []

        func finishCurrent() {
            if !current.isEmpty {
                groups.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for message in messages {
            if message.role == .user, !current.isEmpty {
                finishCurrent()
            }
            current.append(message)

            if message.role == .tool {
                continue
            }
            if message.role == .assistant, message.toolCalls?.isEmpty != false {
                finishCurrent()
            }
        }
        finishCurrent()

        return mergeOrphanedToolGroups(groups)
    }

    private static func mergeOrphanedToolGroups(
        _ groups: [[ChatMessage]]
    ) -> [[ChatMessage]] {
        var result: [[ChatMessage]] = []
        for group in groups {
            guard group.first?.role == .tool else {
                result.append(group)
                continue
            }
            guard let previous = result.popLast() else {
                result.append(group)
                continue
            }
            result.append(previous + group)
        }
        return result
    }
}
