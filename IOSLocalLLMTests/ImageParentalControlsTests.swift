import XCTest
import Combine
@testable import IOSLocalLLM

@MainActor
final class ImageParentalControlsTests: XCTestCase {
    func testRestrictionSurvivesRestartAndCannotBeChangedWithoutPIN() {
        var storage: Data?
        let controls = ImageGenerationParentalControls(read: { storage }, write: { storage = $0 })
        XCTAssertTrue(controls.setPIN("123456", confirmation: "123456"))
        XCTAssertFalse(controls.canGenerate)
        XCTAssertFalse(controls.setPIN("987654", confirmation: "987654"))
        XCTAssertFalse(controls.removeRestriction())

        let restarted = ImageGenerationParentalControls(read: { storage }, write: { storage = $0 })
        XCTAssertFalse(restarted.canGenerate)
        XCTAssertFalse(restarted.unlock(pin: "000000"))
        XCTAssertTrue(restarted.unlock(pin: "123456"))
        XCTAssertTrue(restarted.canGenerate)
        restarted.lock()
        XCTAssertFalse(restarted.canGenerate)
    }

    func testRetryLimitSurvivesRestartAndExpires() {
        var storage: Data?
        var time = Date(timeIntervalSince1970: 1_000)
        let controls = ImageGenerationParentalControls(read: { storage }, write: { storage = $0 }, now: { time })
        XCTAssertTrue(controls.setPIN("123456", confirmation: "123456"))
        for _ in 0..<5 { XCTAssertFalse(controls.unlock(pin: "000000")) }
        let restarted = ImageGenerationParentalControls(read: { storage }, write: { storage = $0 }, now: { time })
        XCTAssertFalse(restarted.unlock(pin: "123456"))
        time = time.addingTimeInterval(301)
        XCTAssertTrue(restarted.unlock(pin: "123456"))
        XCTAssertTrue(restarted.removeRestriction())
        XCTAssertNil(storage)
    }

    func testCorruptOrUnreadableKeychainFailsClosed() {
        let corrupt = ImageGenerationParentalControls(read: { Data("invalid".utf8) }, write: { _ in })
        XCTAssertFalse(corrupt.canGenerate)
        XCTAssertFalse(corrupt.setPIN("123456", confirmation: "123456"))
        let unavailable = ImageGenerationParentalControls(read: { throw CocoaError(.fileReadNoPermission) }, write: { _ in })
        XCTAssertFalse(unavailable.canGenerate)
    }

    func testFailedPINSaveDoesNotClaimProtectionWasEnabled() {
        let controls = ImageGenerationParentalControls(read: { nil }, write: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertFalse(controls.setPIN("123456", confirmation: "123456"))
        XCTAssertNotNil(controls.lastError)
        XCTAssertFalse(controls.isRestricted)
    }
}

@MainActor
final class ImageModelDownloadTests: XCTestCase {
    private func temporaryRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func unlockedControls() -> ImageGenerationParentalControls {
        ImageGenerationParentalControls(read: { nil }, write: { _ in })
    }

    private func writeDownloadedFile(to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download fixture".utf8).write(to: destination)
        return destination
    }

    private func finishDownload(_ service: ImageGenerationService, model: ImageGenerationService.Model) async {
        let finished = expectation(description: "Download finishes")
        let observation = service.$directDownloadProgress.dropFirst()
            .filter { $0[model.id] == nil }.prefix(1)
            .sink { _ in finished.fulfill() }
        service.startDownload(model)
        await fulfillment(of: [finished], timeout: 5)
        observation.cancel()
    }

    func testDownloadNeedsNoPromptAndDoesNotGenerateAnImage() async throws {
        let model = try XCTUnwrap(ImageGenerationService.model(forID: "stabilityai/sd-turbo"))
        var requests: [URL] = []
        let service = ImageGenerationService(repositoryRoot: try temporaryRepository(), parentalControls: unlockedControls()) { url, destination, progress in
            requests.append(url)
            progress(1, 2)
            return try self.writeDownloadedFile(to: destination)
        }
        await finishDownload(service, model: model)

        XCTAssertTrue(service.isInstalled(model))
        XCTAssertEqual(service.state, .ready)
        XCTAssertFalse(service.isBusy)
        XCTAssertNil(service.image)
        XCTAssertNil(service.directDownloadErrors[model.id])
        XCTAssertEqual(requests.count, Set(model.config.files.values).count)
        XCTAssertTrue(requests.allSatisfy { $0.path.contains("/resolve/\(model.revision)/") })
        let requestCount = requests.count
        service.startDownload(model)
        XCTAssertEqual(requests.count, requestCount)
        XCTAssertFalse(service.isDownloading(model))
    }

    func testFailedDownloadCanRetryWithoutRedownloadingCompletedFiles() async throws {
        let model = try XCTUnwrap(ImageGenerationService.model(forID: "stabilityai/sd-turbo"))
        var requests: [URL] = []
        var fail = true
        let service = ImageGenerationService(repositoryRoot: try temporaryRepository(), parentalControls: unlockedControls()) { url, destination, _ in
            requests.append(url)
            if fail && requests.count == 2 { throw URLError(.notConnectedToInternet) }
            return try self.writeDownloadedFile(to: destination)
        }
        await finishDownload(service, model: model)
        XCTAssertFalse(service.isInstalled(model))
        XCTAssertFalse(service.isDownloading(model))
        XCTAssertNotNil(service.directDownloadErrors[model.id])
        let completedFile = try XCTUnwrap(requests.first)

        fail = false
        await finishDownload(service, model: model)
        XCTAssertTrue(service.isInstalled(model))
        XCTAssertNil(service.directDownloadErrors[model.id])
        XCTAssertEqual(requests.filter { $0 == completedFile }.count, 1)
        XCTAssertNil(service.image)
    }

    func testCancelStopsTransferWithoutReportingFailureOrCompletion() async throws {
        let model = try XCTUnwrap(ImageGenerationService.model(forID: "stabilityai/sd-turbo"))
        let transferStarted = expectation(description: "Transfer starts")
        let finished = expectation(description: "Cancellation clears progress")
        var calls = 0
        let service = ImageGenerationService(repositoryRoot: try temporaryRepository(), parentalControls: unlockedControls()) { _, destination, _ in
            calls += 1
            transferStarted.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return try self.writeDownloadedFile(to: destination)
        }
        let observation = service.$directDownloadProgress.dropFirst()
            .filter { $0[model.id] == nil }.prefix(1)
            .sink { _ in finished.fulfill() }
        service.startDownload(model)
        service.startDownload(model)
        await fulfillment(of: [transferStarted], timeout: 5)
        service.cancelDownload(model)
        await fulfillment(of: [finished], timeout: 5)
        observation.cancel()

        XCTAssertEqual(calls, 1, "A second tap must not create another transfer")
        XCTAssertFalse(service.isInstalled(model))
        XCTAssertFalse(service.isDownloading(model))
        XCTAssertNil(service.directDownloadErrors[model.id])
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.image)
    }

    func testParentalLockPreventsStandaloneDownload() throws {
        let model = try XCTUnwrap(ImageGenerationService.model(forID: "stabilityai/sd-turbo"))
        let controls = unlockedControls()
        XCTAssertTrue(controls.setPIN("123456", confirmation: "123456"))
        let service = ImageGenerationService(repositoryRoot: try temporaryRepository(), parentalControls: controls) { _, destination, _ in
            XCTFail("A locked image feature must not start a transfer")
            return destination
        }
        service.startDownload(model)
        XCTAssertFalse(service.isDownloading(model))
        XCTAssertFalse(service.isInstalled(model))
    }

    func testBackgroundCleanupKeepsUnrestrictedDownloadRunning() async throws {
        let model = try XCTUnwrap(ImageGenerationService.model(forID: "stabilityai/sd-turbo"))
        let started = expectation(description: "Transfer starts")
        let finished = expectation(description: "Download finishes after background cleanup")
        var firstFile = true
        let service = ImageGenerationService(repositoryRoot: try temporaryRepository(), parentalControls: unlockedControls()) { _, destination, _ in
            if firstFile {
                firstFile = false
                started.fulfill()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return try self.writeDownloadedFile(to: destination)
        }
        let observation = service.$directDownloadProgress.dropFirst()
            .filter { $0[model.id] == nil }.prefix(1)
            .sink { _ in finished.fulfill() }
        service.startDownload(model)
        await fulfillment(of: [started], timeout: 5)
        service.clearForParentalLock()
        await fulfillment(of: [finished], timeout: 5)
        observation.cancel()
        XCTAssertTrue(service.isInstalled(model))
        XCTAssertNil(service.image)
    }

    func testParentalLockCancelsActiveDownload() async throws {
        let model = try XCTUnwrap(ImageGenerationService.model(forID: "stabilityai/sd-turbo"))
        let started = expectation(description: "Transfer starts")
        let finished = expectation(description: "Locked download stops")
        let controls = unlockedControls()
        let service = ImageGenerationService(repositoryRoot: try temporaryRepository(), parentalControls: controls) { _, destination, _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return destination
        }
        let observation = service.$directDownloadProgress.dropFirst()
            .filter { $0[model.id] == nil }.prefix(1)
            .sink { _ in finished.fulfill() }
        service.startDownload(model)
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(controls.setPIN("123456", confirmation: "123456"))
        service.clearForParentalLock()
        await fulfillment(of: [finished], timeout: 5)
        observation.cancel()
        XCTAssertFalse(service.isDownloading(model))
        XCTAssertFalse(service.isInstalled(model))
        XCTAssertNil(service.directDownloadErrors[model.id])
    }
}
