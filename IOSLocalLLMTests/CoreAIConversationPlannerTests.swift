import XCTest
@testable import IOSLocalLLM

final class CoreAIConversationPlannerTests: XCTestCase {

    func testReasoningOnlyPackCannotBeForcedIntoNoThinkMode() {
        XCTAssertTrue(CoreAIZooCatalog.model(id: "zoo-lfm25-2.6b")?.requiresThinking == true)
        XCTAssertFalse(CoreAIZooCatalog.model(id: "zoo-qwen35-0.8b")?.requiresThinking == true)
    }

    func testPlanSplitsSystemHistoryAndLatestUser() {
        let messages = [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hi"),
            ChatMessage(role: .assistant, content: "Hello."),
            ChatMessage(role: .user, content: "What is 2+2?"),
        ]
        let plan = CoreAIConversationPlanner.plan(messages: messages)
        XCTAssertEqual(plan?.system, "Be brief.")
        XCTAssertEqual(plan?.latestUser, "What is 2+2?")
        XCTAssertEqual(
            plan?.history,
            [.user("Hi"), .assistant("Hello.")]
        )
    }

    func testPlanReturnsNilWithoutAUserTurn() {
        XCTAssertNil(CoreAIConversationPlanner.plan(messages: [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .assistant, content: "Hello."),
        ]))
    }

    func testCompactPromptPolicyReplacesLargeSharedToolCatalog() {
        let originalSystem = "Be helpful.\n\n"
            + CodingAssistantService.groundingPrompt
            + "\n\n"
            + CodingAssistantService.responseFormattingPrompt
            + ToolRunner.systemPromptAddendum
        let adjusted = CoreAIConversationPlanner.applyingCompactPromptPolicy(
            to: [
                ChatMessage(role: .system, content: originalSystem),
                ChatMessage(role: .user, content: "Remember that my project is called Atlas."),
                ChatMessage(role: .assistant, content: "I'll remember Atlas."),
                ChatMessage(role: .user, content: "What is it called?"),
            ],
            toolsEnabled: true
        )

        let system = adjusted.first?.content ?? ""
        XCTAssertFalse(system.contains(ToolRunner.systemPromptAddendum))
        XCTAssertFalse(system.contains(CodingAssistantService.responseFormattingPrompt))
        XCTAssertTrue(system.contains(CodingAssistantService.compactGroundingPrompt))
        XCTAssertTrue(system.contains(ToolRunner.coreAISystemPromptAddendum))
        XCTAssertLessThan(system.count, originalSystem.count / 2)
    }

    func testCompactPromptPolicyIsIdempotentAndKeepsImmediateContext() {
        let source = [
            ChatMessage(
                role: .system,
                content: "Be helpful." + ToolRunner.systemPromptAddendum
            ),
            ChatMessage(role: .user, content: "My launch codename is Atlas."),
            ChatMessage(role: .assistant, content: "Understood. The codename is Atlas."),
            ChatMessage(role: .user, content: "What was the codename?"),
        ]
        let once = CoreAIConversationPlanner.applyingCompactPromptPolicy(
            to: source,
            toolsEnabled: true
        )
        let twice = CoreAIConversationPlanner.applyingCompactPromptPolicy(
            to: once,
            toolsEnabled: true
        )
        let trimmed = CodingAssistantService.trimToInputBudget(
            twice,
            maxTokens: 640
        )

        XCTAssertEqual(once, twice)
        XCTAssertTrue(trimmed.contains { $0.content == "My launch codename is Atlas." })
        XCTAssertTrue(trimmed.contains { $0.content.contains("codename is Atlas") })
        XCTAssertEqual(trimmed.last?.content, "What was the codename?")
    }

    func testOversizedLatestAttachmentIsHardBoundedForCoreAI() {
        let question = "Explain this file"
        let source = [
            ChatMessage(role: .system, content: String(repeating: "instruction ", count: 90)),
            ChatMessage(
                role: .user,
                content: question,
                modelContent: "ATTACHED FILES\nFile [1]: sample.swift\n```\n"
                    + String(repeating: "let value = 42\n", count: 4_000)
                    + "```\n\n\(question)"
            ),
        ]

        let bounded = CoreAIConversationPlanner.boundedRuntimeMessages(
            source,
            maxTokens: 640
        )

        XCTAssertLessThanOrEqual(
            CoreAIConversationPlanner.estimatedRuntimeTokens(in: bounded),
            640
        )
        XCTAssertTrue(bounded.last?.contentForModel.contains("File [1]: sample.swift") == true)
        XCTAssertTrue(bounded.last?.contentForModel.hasSuffix(question) == true)
        XCTAssertTrue(bounded.last?.contentForModel.contains("content shortened") == true)
    }

    func testCoreAIHardBoundaryDoesNotChangeMessagesThatAlreadyFit() {
        let source = [
            ChatMessage(role: .system, content: "Be concise."),
            ChatMessage(role: .user, content: "My codename is Atlas."),
            ChatMessage(role: .assistant, content: "Understood."),
            ChatMessage(role: .user, content: "What is my codename?"),
        ]

        XCTAssertEqual(
            CoreAIConversationPlanner.boundedRuntimeMessages(source, maxTokens: 640),
            source
        )
    }

    func testToolResultFenceUsesTheRealToolName() {
        let id = UUID()
        let message = ChatMessage(
            id: id,
            role: .user,
            content: """
            ```tool_result
            {"name":"web_search","result":"Paris is the capital of France."}
            ```
            """
        )
        let parsed = CoreAIConversationPlanner.toolIdentity(from: message)
        XCTAssertEqual(parsed.name, "web_search")
        XCTAssertTrue(CoreAIConversationPlanner.looksLikeToolResult(message))
    }

    func testAPIToolResultPrefixIsNotTreatedAsTheLatestUserTurn() {
        let messages = [
            ChatMessage(role: .user, content: "Search for Paris"),
            ChatMessage(role: .assistant, content: "I'll search."),
            ChatMessage(
                role: .user,
                content: "[Tool result for call_id=call_1]\nParis is the capital."
            ),
            ChatMessage(role: .user, content: "Summarize that."),
        ]
        let plan = CoreAIConversationPlanner.plan(messages: messages)
        XCTAssertEqual(plan?.latestUser, "Summarize that.")
        XCTAssertEqual(plan?.history.last, .tool(
            id: "call_1",
            name: "tool",
            content: "[Tool result for call_id=call_1]\nParis is the capital."
        ))
    }

    func testTrailingAssistantToolResultBecomesFollowUpPrompt() {
        let result = ChatMessage(
            role: .user,
            content: """
            ```tool_result
            {"name":"knowledge_base","result":"No relevant passages found."}
            ```
            """
        )
        let plan = CoreAIConversationPlanner.plan(messages: [
            ChatMessage(role: .user, content: "What is the Mandela effect?"),
            result,
        ])

        XCTAssertEqual(plan?.history, [.user("What is the Mandela effect?")])
        XCTAssertEqual(
            plan?.latestUser,
            result.content.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func testExplicitToolRoleParsesJSONName() {
        let message = ChatMessage(
            role: .tool,
            content: "{\"name\":\"calculator\",\"result\":\"4\"}"
        )
        let turn = CoreAIConversationPlanner.toolTurn(from: message)
        XCTAssertEqual(turn, .tool(
            id: message.id.uuidString,
            name: "calculator",
            content: "{\"name\":\"calculator\",\"result\":\"4\"}"
        ))
    }

    func testAttachedImagesAreDetected() {
        let empty = ChatMessage(role: .user, content: "hello")
        XCTAssertFalse(empty.hasAttachedImages)
        let attached = ChatMessage(
            role: .user,
            content: "what is this",
            imageThumbnailData: Data([0x01])
        )
        XCTAssertTrue(attached.hasAttachedImages)
    }
}

@MainActor
final class CoreAIInferenceIdentityTests: XCTestCase {
    func testNormalizedSelectionIDAddsPrefixOnce() {
        XCTAssertEqual(
            CoreAIInferenceService.normalizedSelectionID("zoo-qwen3-0.6b-official-ios"),
            "coreai:zoo-qwen3-0.6b-official-ios"
        )
        XCTAssertEqual(
            CoreAIInferenceService.normalizedSelectionID("coreai:zoo-qwen3-0.6b-official-ios"),
            "coreai:zoo-qwen3-0.6b-official-ios"
        )
    }

    func testReadyRuntimeDoesNotMatchADifferentPack() {
        XCTAssertTrue(
            CoreAIInferenceService.isCurrentRuntime(
                loadedID: "zoo-qwen3-0.6b-official-ios",
                ready: true,
                requestedID: "coreai:zoo-qwen3-0.6b-official-ios"
            )
        )
        XCTAssertFalse(
            CoreAIInferenceService.isCurrentRuntime(
                loadedID: "zoo-qwen3-0.6b-official-ios",
                ready: true,
                requestedID: "coreai:zoo-qwen3-4b-official-ios"
            )
        )
        XCTAssertFalse(
            CoreAIInferenceService.isCurrentRuntime(
                loadedID: "zoo-qwen3-0.6b-official-ios",
                ready: false,
                requestedID: "coreai:zoo-qwen3-0.6b-official-ios"
            )
        )
    }

    func testMissingModelErrorDoesNotMentionAServer() {
        XCTAssertEqual(
            CoreAIInferenceError.modelMissing.errorDescription,
            "Download a Core AI pack from the Models tab first."
        )
        XCTAssertFalse(
            CoreAIInferenceError.modelMissing.errorDescription?.contains("server") == true
        )
    }

    func testSharedRuntimeStartsUnloaded() {
        XCTAssertFalse(
            CoreAIInferenceService.shared.isLoaded(as: "coreai:zoo-qwen3-0.6b-official-ios")
        )
    }
}
