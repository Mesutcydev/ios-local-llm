import XCTest
@testable import IOSLocalLLM

final class AssistantActivityCardTests: XCTestCase {

    func test_streamingStatus_defaultsToGenerating() {
        XCTAssertEqual(
            AssistantActivity.streamingStatus(content: "Hello", detectedToolName: nil),
            .generating
        )
    }

    func test_streamingStatus_openThinkIsReasoning() {
        XCTAssertEqual(
            AssistantActivity.streamingStatus(content: "<think>planning", detectedToolName: nil),
            .reasoning
        )
    }

    func test_streamingStatus_closedThinkIsGenerating() {
        XCTAssertEqual(
            AssistantActivity.streamingStatus(
                content: "<think>plan</think>\nAnswer",
                detectedToolName: nil
            ),
            .generating
        )
    }

    func test_streamingStatus_detectedToolWinsOverReasoning() {
        XCTAssertEqual(
            AssistantActivity.streamingStatus(
                content: "<think>need search",
                detectedToolName: "web_search"
            ),
            .preparingTool("web_search")
        )
    }

    func test_parseToolResult_readsNameAndBody() {
        let raw = """
        ```tool_result
        {"name":"web_search","result":"Paris is the capital."}
        ```
        """
        let parsed = AssistantActivity.parseToolResult(raw)
        XCTAssertEqual(parsed?.name, "web_search")
        XCTAssertEqual(parsed?.result, "Paris is the capital.")
    }

    func test_parseToolResult_ignoresPlainUserText() {
        XCTAssertNil(AssistantActivity.parseToolResult("search the web for Paris"))
    }

    func test_displayName_andSymbol() {
        XCTAssertEqual(AssistantActivity.displayName(forTool: "web_search"), "Web Search")
        XCTAssertEqual(AssistantActivity.symbol(forTool: "web_search"), "globe")
        XCTAssertEqual(AssistantActivity.symbol(forTool: "file_read"), "doc.text")
        XCTAssertEqual(AssistantActivity.symbol(forTool: "generate_image"), "eye")
    }

    func test_statusTitle_isHuman() {
        XCTAssertEqual(
            AssistantActivity.statusTitle(.awaitingApproval("web_search")),
            "Needs approval · Web Search"
        )
        XCTAssertEqual(
            AssistantActivity.statusTitle(.runningTool("file_read")),
            "Running File Read"
        )
    }

    func test_stopAbortsToolFollowUp() {
        XCTAssertFalse(AssistantActivity.shouldFollowUpAfterTool(aborted: true))
        XCTAssertTrue(AssistantActivity.shouldFollowUpAfterTool(aborted: false))
    }

    func test_canResumeTruncatedReply_onlyWhenCutOffAndIdle() {
        XCTAssertTrue(
            AssistantActivity.canResumeTruncatedReply(
                hitTokenLimit: true,
                isStreaming: false,
                wasInterrupted: false
            )
        )
        XCTAssertFalse(
            AssistantActivity.canResumeTruncatedReply(
                hitTokenLimit: true,
                isStreaming: true,
                wasInterrupted: false
            )
        )
        XCTAssertFalse(
            AssistantActivity.canResumeTruncatedReply(
                hitTokenLimit: true,
                isStreaming: false,
                wasInterrupted: true
            )
        )
        XCTAssertFalse(
            AssistantActivity.canResumeTruncatedReply(
                hitTokenLimit: false,
                isStreaming: false,
                wasInterrupted: false
            )
        )
    }

    func test_continuationIndex_isLastCutOffAssistant() {
        let messages = [
            ChatMessage(role: .user, content: "Write a long essay"),
            ChatMessage(role: .assistant, content: "Once upon", hitTokenLimit: true),
        ]
        XCTAssertEqual(AssistantActivity.continuationMessageIndex(in: messages), 1)
        XCTAssertNil(AssistantActivity.continuationMessageIndex(in: [
            ChatMessage(role: .user, content: "Hi"),
            ChatMessage(role: .assistant, content: "Hello"),
        ]))
    }

    func test_toolResultSummary_isKindSpecific() {
        XCTAssertEqual(
            AssistantActivity.toolResultKind(name: "calculator"),
            .calculator
        )
        XCTAssertEqual(
            AssistantActivity.toolResultSummary(name: "calculator", result: "42"),
            "42"
        )
        XCTAssertEqual(
            AssistantActivity.toolResultKind(name: "file_read"),
            .file
        )
        XCTAssertTrue(
            AssistantActivity.toolResultSummary(
                name: "file_read",
                result: "Notes.txt\nhello world"
            ).localizedCaseInsensitiveContains("file")
        )
        XCTAssertEqual(
            AssistantActivity.citationTitle(visibleCount: 3),
            "Used 3 web sources"
        )
    }

    func test_imageGenerationSubtitle_reportsProgress() {
        XCTAssertEqual(
            AssistantActivity.imageGenerationSubtitle(.generating(0.4)),
            "Generating · 40%"
        )
        XCTAssertEqual(
            AssistantActivity.imageGenerationSubtitle(.loading),
            "Loading image model"
        )
    }
}
