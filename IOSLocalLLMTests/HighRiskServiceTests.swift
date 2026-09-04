import XCTest
@testable import IOSLocalLLM

// Focused regression coverage for the three services with the largest
// persistence, download, and inference blast radius.

final class ModelDownloadCenterServiceTests: XCTestCase {
    @MainActor
    func testDownloadableVisionModelAppearsInAssistantAndVisionCategories() {
        let model = DownloadableModel(
            id: "test-vlm",
            displayName: "Test VLM",
            subtitle: "Qwen/Test-VL",
            sizeLabel: "1 GB",
            category: .assistant,
            repoID: "Qwen/Test-VL",
            capabilities: [.vision]
        )

        XCTAssertEqual(model.sourceRepoID, "Qwen/Test-VL")
        XCTAssertEqual(model.vendor, .qwen)
        XCTAssertTrue(model.supportsCategory(.assistant))
        XCTAssertTrue(model.supportsCategory(.vlm))
        XCTAssertFalse(model.supportsCategory(.voice))
    }

    @MainActor
    func testModelWithoutDownloaderHasSafeIdleState() {
        let model = DownloadableModel(
            id: "metadata-only",
            displayName: "Metadata Only",
            subtitle: "example/model",
            sizeLabel: "Unknown",
            category: .assistant
        )

        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.progress, 0)
        XCTAssertFalse(model.isReady)
    }
}

final class CodingAssistantServicePolicyTests: XCTestCase {
    func testStorageBackedGGUFPolicyDisablesGPULayersAndBoundsHeadroom() {
        let policy = GGUFLoadPolicy.resolve(
            fileBytes: 8 * 1_024 * 1_024 * 1_024,
            pagingEnabled: true
        )

        XCTAssertTrue(policy.storageBacked)
        XCTAssertEqual(policy.gpuLayers, 0)
        XCTAssertEqual(
            policy.minimumAvailableBytes,
            GGUFLoadPolicy.storageBackedHeadroom
        )
    }

    func testNormalLargeGGUFPolicyKeepsAcceleratedLayerBudget() {
        let policy = GGUFLoadPolicy.resolve(
            fileBytes: 4 * 1_024 * 1_024 * 1_024,
            pagingEnabled: false
        )

        XCTAssertFalse(policy.storageBacked)
        XCTAssertEqual(policy.gpuLayers, 12)
        XCTAssertGreaterThan(policy.minimumAvailableBytes, 4_000_000_000)
    }

    func testDisabledLowMemoryPolicyDoesNotOverrideAllocatorLimits() {
        let policy = MLXLowMemoryPolicy.resolve(
            enabled: false,
            physicalMemoryBytes: 8_000_000_000,
            processCeilingBytes: 6_000_000_000
        )

        XCTAssertNil(policy.memoryLimitBytes)
        XCTAssertNil(policy.cacheLimitBytes)
    }
}

final class CloudSyncServiceTests: XCTestCase {
    func testPartialPushErrorReportsFailedAndTotalCounts() {
        let error = CloudSyncError.partialPush(failed: 2, total: 5)
        XCTAssertEqual(
            error.errorDescription,
            "iCloud sync incomplete — 2 of 5 conversations failed to upload."
        )
    }

    func testDeletionTombstoneRoundTrip() throws {
        let id = UUID()
        CloudSyncTombstones.clear(id.uuidString)
        defer { CloudSyncTombstones.clear(id.uuidString) }

        CloudSyncTombstones.mark(id)
        let deletionDate = try XCTUnwrap(
            CloudSyncTombstones.deletionDate(id.uuidString)
        )

        XCTAssertLessThan(abs(deletionDate.timeIntervalSinceNow), 2)
        CloudSyncTombstones.clear(id.uuidString)
        XCTAssertNil(CloudSyncTombstones.deletionDate(id.uuidString))
    }
}

@MainActor
final class DownloadLifecycleReleaseTests: XCTestCase {
    func testCancelThenRetryWaitsForOldRunAndPreservesReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("config.json")
        try Data("old".utf8).write(to: file)
        var first: CheckedContinuation<(Data, URLResponse), Error>?
        var calls = 0
        let manager = HFModelDownloadManager(repoID: "test/model", destination: root) { request in
            calls += 1
            if calls == 1 {
                return try await withCheckedThrowingContinuation { first = $0 }
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
            return (Data(#"[{"type":"file","path":"config.json","size":2}]"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        manager.start()
        manager.start()
        while first == nil { await Task.yield() }
        XCTAssertEqual(calls, 1)
        manager.cancel()
        manager.start()
        await Task.yield()
        XCTAssertEqual(calls, 1, "Retry must wait for the old operation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        first!.resume(throwing: URLError(.cancelled))
        for _ in 0..<10_000 {
            if manager.state == .ready { break }
            await Task.yield()
        }
        XCTAssertEqual(manager.state, .ready)
        XCTAssertEqual(try Data(contentsOf: file), Data("{}".utf8))
        XCTAssertEqual(calls, 2)
    }

    func testSecondDeletionCannotReportSuccessBeforeTheFirstFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var pending: CheckedContinuation<(Data, URLResponse), Error>?
        let manager = HFModelDownloadManager(repoID: "test/model", destination: root) { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        manager.start()
        while pending == nil { await Task.yield() }
        let deletion = Task { try await manager.delete() }
        while manager.state.isActive { await Task.yield() }
        do {
            try await manager.delete()
            XCTFail("A duplicate caller must not unregister a model while deletion is pending")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
        pending!.resume(throwing: URLError(.cancelled))
        try await deletion.value
    }

    func testDeletingAllowlistedVariantPreservesSibling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.appendingPathComponent("sibling.bin")
        let selected = root.appendingPathComponent("selected.bin")
        try Data([1]).write(to: sibling)
        try Data([2]).write(to: selected)
        let manager = HFModelDownloadManager(repoID: "test/model", destination: root,
                                            fileAllowlist: ["selected.bin"])
        try await manager.delete()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    }

    func testCancellationBeforeTaskRegistrationCancelsOnlyThatTask() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let first = session.downloadTask(with: URL(string: "https://example.com/a")!)
        let sibling = session.downloadTask(with: URL(string: "https://example.com/b")!)
        let cancellation = DownloadCancellation()
        cancellation.cancel()
        cancellation.install(first)
        XCTAssertTrue(first.state == .canceling || first.state == .completed)
        XCTAssertEqual(sibling.state, .suspended)
    }
}

@MainActor
final class CloudSyncReleaseTests: XCTestCase {
    func testAllPagesAreCollectedIncludingAnEmptyIntermediatePage() async throws {
        var cursors: [Int?] = []
        let result: [Int] = try await CloudSyncService.collectPages { (cursor: Int?) in
            cursors.append(cursor)
            switch cursor {
            case nil: return ([1, 2], 1)
            case 1: return ([], 2)
            default: return ([3], nil)
            }
        }
        XCTAssertEqual(result, [1, 2, 3])
        XCTAssertEqual(cursors.count, 3)
    }

    func testPageFailureDoesNotReturnPartialHistory() async {
        do {
            let _: [Int] = try await CloudSyncService.collectPages { (cursor: Int?) in
                if cursor == nil { return ([1], 1) }
                throw URLError(.networkConnectionLost)
            }
            XCTFail("Partial history must not be merged")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
    }

    func testConcurrentSyncAndOptOutDuringAvailability() async {
        var pending: CheckedContinuation<Bool, Never>?
        var enabled = true
        var syncCount = 0
        let service = CloudSyncService(availability: {
            await withCheckedContinuation { pending = $0 }
        }, synchronize: { syncCount += 1 }, isEnabled: { enabled })
        let first = Task { await service.syncNow() }
        while pending == nil { await Task.yield() }
        XCTAssertTrue(service.isSyncing)
        await service.syncNow()
        enabled = false
        pending!.resume(returning: true)
        await first.value
        XCTAssertEqual(syncCount, 0)
        XCTAssertNil(service.lastSyncAt)
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isSyncing)
    }
}
