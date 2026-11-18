import XCTest
@testable import IOSLocalLLM

final class SharedContentInboxTests: XCTestCase {
    func testQueryValuesPreserveAmpersandsFragmentsAndUnicode() throws {
        for (key, value) in [
            ("text", "a & b = c? # café + 你好"),
            ("url", "https://example.com/?a=1&b=2#section")
        ] {
            let url = try SharedContentInbox.handOffURL(queryName: key, value: value)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.name, key)
            XCTAssertEqual(items.first?.value, value)
        }
    }

    func testSharesAreConsumedOnceInOrderAndSurviveAnotherCaller() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let now = Date()
        let first = try SharedContentInbox.handOffURL(queryName: "text", value: "First share")
        let second = try SharedContentInbox.handOffURL(queryName: "textfile", value: "share-fixture.txt")
        try SharedContentInbox.save(second, in: container, now: now)
        try SharedContentInbox.save(first, in: container, now: now.addingTimeInterval(-1))
        XCTAssertEqual(SharedContentInbox.takeNext(in: container, now: now), first)
        XCTAssertEqual(SharedContentInbox.takeNext(in: container, now: now), second)
        XCTAssertNil(SharedContentInbox.takeNext(in: container, now: now))
    }

    func testExpiredCorruptAndOversizedSharesCannotOpenURLs() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let now = Date()
        let url = try SharedContentInbox.handOffURL(queryName: "text", value: "Expired share")
        let expired = try SharedContentInbox.save(url, in: container, now: now.addingTimeInterval(-86_401))
        let directory = container.appendingPathComponent(SharedContentInbox.directoryName)
        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("invalid".utf8).write(to: corrupt)
        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: 32 * 1024 + 1).write(to: oversized)
        XCTAssertNil(SharedContentInbox.takeNext(in: container, now: now))
        for file in [expired, corrupt, oversized] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        XCTAssertThrowsError(try SharedContentInbox.save(URL(string: "https://example.com")!, in: container))
    }

    func testLegacyAppStoreLinksAreAcceptedAndOtherSchemesRejected() {
        XCTAssertTrue(SharedContentInbox.isShareURL(URL(string: "codelens://share?text=hello")!))
        XCTAssertTrue(SharedContentInbox.isShareURL(URL(string: "ios-local-llm://share?text=hello")!))
        XCTAssertFalse(SharedContentInbox.isShareURL(URL(string: "ios-local-llm://other?text=hello")!))
        XCTAssertFalse(SharedContentInbox.isShareURL(URL(string: "https://share?text=hello")!))
    }

    @MainActor
    func testForegroundCallbacksDoNotOverwriteAComposerAfterFirstImport() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let now = Date()
        try SharedContentInbox.save(SharedContentInbox.handOffURL(queryName: "text", value: "First"),
                                    in: container, now: now.addingTimeInterval(-1))
        try SharedContentInbox.save(SharedContentInbox.handOffURL(queryName: "text", value: "Second"),
                                    in: container, now: now)
        let bridge = AppBridge()
        bridge.receiveSavedShare(afterSetup: true, from: container)
        XCTAssertEqual(bridge.pendingSharedText?.body, "First")
        bridge.pendingSharedText = nil // The view has copied it to its composer.
        bridge.receiveSavedShare(afterSetup: true, from: container)
        XCTAssertNil(bridge.pendingSharedText)
        bridge.beginNextShareVisit()
        bridge.receiveSavedShare(afterSetup: true, from: container)
        XCTAssertEqual(bridge.pendingSharedText?.body, "Second")
    }

    @MainActor
    func testShareStaysQueuedUntilSetupFinishes() throws {
        let container = try makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let envelope = try SharedContentInbox.save(
            SharedContentInbox.handOffURL(queryName: "text", value: "After setup"), in: container)
        let bridge = AppBridge()
        bridge.receiveSavedShare(afterSetup: false, from: container)
        XCTAssertNil(bridge.pendingSharedText)
        XCTAssertNil(bridge.requestedTab)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        bridge.receiveSavedShare(afterSetup: true, from: container)
        XCTAssertEqual(bridge.pendingSharedText?.body, "After setup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
    }

    @MainActor
    func testLegacyLinkPrefillsComposerWithoutAutomaticallySending() {
        let bridge = AppBridge()
        bridge.handleIncomingURL(URL(string: "codelens://share?text=Saved%20question")!)
        XCTAssertEqual(bridge.pendingSharedText?.body, "Saved question")
        XCTAssertEqual(bridge.pendingSharedText?.autoSend, false)
        XCTAssertEqual(bridge.requestedTab, AppBridge.Tab.assistant.rawValue)
    }

    private func makeContainer() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
