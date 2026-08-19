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
}
