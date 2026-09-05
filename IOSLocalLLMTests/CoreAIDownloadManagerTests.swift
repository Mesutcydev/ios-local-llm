import XCTest
@testable import IOSLocalLLM

@MainActor
final class CoreAIDownloadManagerTests: XCTestCase {
    func testStartPublishesVisibleStateSynchronously() {
        let manager = CoreAIHFDownloadManager(
            id: "test-pack",
            repoID: "owner/repo",
            pathPrefix: "ios",
            displayName: "Test Pack"
        )
        XCTAssertEqual(manager.state, .idle)

        manager.start()

        // The UI reads this in the same event turn as the tap. Leaving `.idle`
        // until a Task happens to execute makes the Download button appear dead.
        XCTAssertEqual(manager.state, .enumerating)
        XCTAssertFalse(manager.statusDetail.isEmpty)
        manager.cancel()
    }
}
