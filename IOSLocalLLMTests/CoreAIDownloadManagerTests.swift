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
        if let reason = CoreAIInferenceService.availabilityReason {
            XCTAssertEqual(manager.state, .failed(reason))
            manager.cancel()
            return
        }
        XCTAssertEqual(manager.state, .enumerating)
        XCTAssertFalse(manager.statusDetail.isEmpty)
        manager.cancel()
    }

    func testUnavailableDownloadFailureRemainsVisibleUntilCleared() throws {
        guard CoreAIInferenceService.availabilityReason != nil else { throw XCTSkip("Unsupported-runtime path") }
        let center = CoreAIDownloadCenter()
        let manager = center.manager(for: CoreAIZooCatalog.downloadableTextModels[0])
        manager.start()
        XCTAssertTrue(center.hasFailures)
        XCTAssertEqual(center.activeCount, 0)
        XCTAssertEqual(center.downloads.count, 1)
        manager.cancel()
        center.removeFinished()
        XCTAssertFalse(center.hasFailures)
        XCTAssertTrue(center.downloads.isEmpty)
    }

    func testStreamingChecksumMatchesKnownDigest() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreAIChecksum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)

        let digest = try await CoreAIHFDownloadManager.sha256(of: file)

        XCTAssertEqual(
            digest,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testRejectsHubPathTraversal() {
        XCTAssertThrowsError(
            try CoreAIHFDownloadManager.validatedRelativePath("ios/../../outside.bin")
        )
        XCTAssertThrowsError(
            try CoreAIHFDownloadManager.validatedRelativePath("/absolute.bin")
        )
        XCTAssertThrowsError(
            try CoreAIHFDownloadManager.validatedRelativePath("ios\\outside.bin")
        )
    }

    func testDestinationStaysInsideStagingRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreAIPath-\(UUID().uuidString)", isDirectory: true)
        let destination = try CoreAIHFDownloadManager.destinationURL(
            root: root,
            relativePath: "ios/model/config.json"
        )

        XCTAssertTrue(destination.path.hasPrefix(root.standardizedFileURL.path + "/"))
    }

    func testCustomIDCannotBecomeStagingPathSyntax() {
        let name = CoreAIHFDownloadManager.stagingDirectoryName(
            for: "hf:../../escape#ios"
        )

        XCTAssertTrue(name.hasPrefix(".download-"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(".."))
    }

    func testMalformedDeclaredChecksumCannotDisableVerification() throws {
        XCTAssertNil(try CoreAIHFDownloadManager.validatedChecksum(nil))
        XCTAssertThrowsError(try CoreAIHFDownloadManager.validatedChecksum("invalid"))
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(try CoreAIHFDownloadManager.validatedChecksum("sha256:" + digest), digest)
    }

    func testRejectsMalformedRepositoryID() {
        XCTAssertThrowsError(
            try CoreAIHFDownloadManager.validatedRepoID("../../escape")
        )
        XCTAssertNoThrow(
            try CoreAIHFDownloadManager.validatedRepoID("owner/model-name")
        )
    }
}
