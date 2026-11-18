import XCTest
import PDFKit
@testable import IOSLocalLLM

final class WebResponseBoundaryTests: XCTestCase {
    private func bytes(_ values: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            values.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func testResponseAcceptsExactLimitAndRejectsFirstExcessByte() async throws {
        let exact = try await WebPageFetchService.collectBounded(bytes([1, 2, 3]), maximumBytes: 3)
        XCTAssertEqual(exact, Data([1, 2, 3]))
        do {
            _ = try await WebPageFetchService.collectBounded(bytes([1, 2, 3, 4]), maximumBytes: 3)
            XCTFail("Oversized response must stop during collection")
        } catch WebToolError.tooLarge(let count) { XCTAssertEqual(count, 4) }
        let empty = try await WebPageFetchService.collectBounded(bytes([]), maximumBytes: 0)
        XCTAssertTrue(empty.isEmpty)
    }

    @MainActor
    func testCancelledCollectionDoesNotReturnBufferedContent() async {
        let task = Task { try await WebPageFetchService.collectBounded(bytes([1]), maximumBytes: 3) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRedirectGuardBlocksPrivateDestinationsBeforeFollowing() async {
        let guardDelegate = WebRedirectGuard(validator: URLSafetyValidator())
        for value in ["http://127.0.0.1/admin", "https://example.local/", "file:///tmp/fixture"] {
            let request = URLRequest(url: URL(string: value)!)
            let permitted = await guardDelegate.validatedRedirectRequest(request)
            XCTAssertNil(permitted, value)
        }
        let permitted = await guardDelegate.validatedRedirectRequest(
            URLRequest(url: URL(string: "https://8.8.8.8/")!)
        )
        XCTAssertEqual(permitted?.url?.host, "8.8.8.8")
    }
}

final class AttachmentBoundaryTests: XCTestCase {
    func testUnicodeCutKeepsCompleteScalarAndGrapheme() {
        XCTAssertEqual(FileAttachmentService.capToBytes("ééx", cap: 4).0, "éé")
        XCTAssertTrue(FileAttachmentService.capToBytes("e\u{301}x", cap: 2).0.isEmpty)
        let clipped = FileAttachmentService.capToBytes(String(repeating: "你好🌍", count: 100), cap: 100)
        XCTAssertTrue(clipped.1)
        XCTAssertLessThanOrEqual(clipped.0.utf8.count, 100)
        XCTAssertFalse(clipped.0.contains("�"))
        XCTAssertTrue(FileAttachmentService.capToBytes("x", cap: 0).0.isEmpty)
    }

    func testPartialUTF8ReadDoesNotFallBackToLatin1ForEntireDocument() {
        let complete = "Résumé 中文 🌍"
        for byteCount in 1...3 {
            let data = Data(complete.utf8) + Data(Array("😀".utf8).prefix(byteCount))
            XCTAssertEqual(FileAttachmentService.decodeTextPrefix(data, truncated: true), complete)
        }
        XCTAssertEqual(FileAttachmentService.decodeTextPrefix(Data("éé".utf8)), "éé")
        XCTAssertEqual(FileAttachmentService.decodeTextPrefix(Data([0x63, 0x61, 0x66, 0xe9])), "café")
    }

    func testLargeTextIsBoundedBeforeItBecomesAnAttachment() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let prefix = "Résumé 中文\n"
        try (Data(prefix.utf8) + Data(repeating: 65, count: 2 * 1024 * 1024)).write(to: url)
        let result = try await FileAttachmentService.read(url)
        XCTAssertTrue(result.extractedText.hasPrefix(prefix))
        XCTAssertLessThanOrEqual(result.byteSize, FileAttachmentService.perFileByteCap)
        XCTAssertNotNil(result.warning)
    }

    @MainActor
    func testCancelledReadPreservesCancellationInsteadOfReportingFileFailure() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let job = Task { try await FileAttachmentService.read(url) }
        job.cancel()
        do { _ = try await job.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPDFSizeLimitIsCheckedBeforeParsing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = FileManager.default.createFile(atPath: url.path, contents: Data())
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 33 * 1024 * 1024)
        try file.close()
        do { _ = try await FileAttachmentService.read(url); XCTFail("Expected PDF size refusal") }
        catch AttachmentError.readFailed(let reason) { XCTAssertTrue(reason.contains("32 MB")) }
    }
}

@MainActor
final class KnowledgeBaseImportBoundaryTests: XCTestCase {
    private func makeService(limit: Int = 5_000, gate: ImportEmbeddingGate) throws -> (KnowledgeBaseService, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("index.json")
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        return (KnowledgeBaseService(indexURL: url, preferences: preferences, maxTotalChunks: limit,
                                     embedding: { text in await gate.embed(text) }), url)
    }

    func testClearInvalidatesAnAlreadyRunningImport() async throws {
        let started = expectation(description: "Embedding started")
        let gate = ImportEmbeddingGate(started: started)
        let (service, url) = try makeService(gate: gate)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = Task { await service.addDocument(name: "fixture", text: "Synthetic document.") }
        await fulfillment(of: [started], timeout: 5)
        service.clear()
        await gate.release()
        await job.value
        XCTAssertTrue(service.documents.isEmpty)
        XCTAssertEqual(service.totalChunks, 0)
        XCTAssertFalse(service.isIndexing)
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((index["documents"] as? [Any])?.count, 0)
    }

    func testWipeDoesNotAllowLateImportToRecreateIndex() async throws {
        let started = expectation(description: "Embedding started")
        let gate = ImportEmbeddingGate(started: started)
        let (service, url) = try makeService(gate: gate)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = Task { await service.addDocument(name: "fixture", text: "Synthetic document.") }
        await fulfillment(of: [started], timeout: 5)
        service.isEnabled = true
        service.wipeFromDisk()
        await gate.release()
        await job.value
        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFreshImportAfterWipeRecreatesPersistenceDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("index.json")
        let preferences = UserDefaults(suiteName: UUID().uuidString)!
        defer { try? FileManager.default.removeItem(at: root) }
        let service = KnowledgeBaseService(indexURL: url, preferences: preferences, embedding: { _ in [1, 0] })
        await service.addDocument(name: "old", text: "Old fixture.")
        try FileManager.default.removeItem(at: root)
        service.wipeFromDisk()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        await service.addDocument(name: "new", text: "New fixture.")
        let reopened = KnowledgeBaseService(indexURL: url, preferences: preferences, embedding: { _ in [1, 0] })
        XCTAssertEqual(reopened.documents.map(\.name), ["new"])
        XCTAssertEqual(reopened.totalChunks, 1)
    }

    func testConcurrentImportsRecheckCapacityAtCommit() async throws {
        let started = expectation(description: "Both imports started")
        started.expectedFulfillmentCount = 2
        let gate = ImportEmbeddingGate(started: started)
        let (service, url) = try makeService(limit: 1, gate: gate)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = Task { await service.addDocument(name: "first", text: "First fixture.") }
        let second = Task { await service.addDocument(name: "second", text: "Second fixture.") }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(service.isIndexing)
        await gate.release()
        await first.value
        await second.value
        XCTAssertEqual(service.totalChunks, 1)
        XCTAssertEqual(service.documents.count, 1)
        XCTAssertFalse(service.isIndexing)
    }

    func testCancellingCallerDoesNotCommitAnImport() async throws {
        let started = expectation(description: "Embedding started")
        let gate = ImportEmbeddingGate(started: started)
        let (service, url) = try makeService(gate: gate)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let job = Task { await service.addDocument(name: "fixture", text: "Synthetic document.") }
        await fulfillment(of: [started], timeout: 5)
        job.cancel()
        await gate.release()
        await job.value
        XCTAssertTrue(service.documents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

private actor ImportEmbeddingGate {
    let started: XCTestExpectation
    private var waiters: [CheckedContinuation<[Float]?, Never>] = []
    init(started: XCTestExpectation) { self.started = started }
    func embed(_ text: String) async -> [Float]? {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            started.fulfill()
        }
    }
    func release() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: [1, 0]) }
    }
}

@MainActor
final class InferenceThermalGuardTests: XCTestCase {
    private func events() -> AsyncStream<Void> {
        AsyncStream { continuation in
            for _ in 0..<3 { continuation.yield(()) }
            continuation.finish()
        }
    }

    func testSeriousStateDoesNotInterruptInference() async throws {
        var stops = 0
        try await InferenceThermalGuard.monitor(events(), readState: { .serious }) { stops += 1 }
        XCTAssertEqual(stops, 0)
    }

    func testAlreadyCriticalStateStopsWithoutWaitingForAnotherNotification() async throws {
        let empty = AsyncStream<Void> { $0.finish() }
        var stops = 0
        try await InferenceThermalGuard.monitor(empty, readState: { .critical }) { stops += 1 }
        XCTAssertEqual(stops, 1)
    }

    func testCriticalStateStopsExactlyOnce() async throws {
        var stops = 0
        try await InferenceThermalGuard.monitor(events(), readState: { .critical }) { stops += 1 }
        XCTAssertEqual(stops, 1)
    }

    func testCancelledWatcherCannotStopAnotherGeneration() async {
        var stops = 0
        let stream = events()
        let task = Task {
            try await InferenceThermalGuard.monitor(stream, readState: { .critical }) { stops += 1 }
        }
        task.cancel()
        _ = try? await task.value
        XCTAssertEqual(stops, 0)
    }
}
