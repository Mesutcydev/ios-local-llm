import Combine
import XCTest
@testable import IOSLocalLLM

final class PerformanceRegressionTests: XCTestCase {
    @MainActor
    func testReadinessRefreshPublishesOnlyChangesAndDetectsRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.bin")
        try Data([1]).write(to: file)
        let downloader = HFModelDownloadManager(
            repoID: "tests/readiness", destination: root, fileAllowlist: ["test.bin"]
        )
        var states: [HFModelDownloadManager.DownloadState] = []
        let subscription = downloader.$state.dropFirst().sink { states.append($0) }
        defer { subscription.cancel() }
        downloader.checkIfReady()
        let initialPublications = states.count
        for _ in 0..<100 { downloader.checkIfReady() }
        XCTAssertEqual(states.count, initialPublications)
        XCTAssertEqual(downloader.state, .ready)
        try FileManager.default.removeItem(at: root)
        downloader.checkIfReady()
        XCTAssertEqual(downloader.state, .idle)
        XCTAssertEqual(states.last, .idle)
    }

    @MainActor
    func testStorageRefreshSerializesBurstAndPublishesNewestSnapshot() async {
        let gate = RefreshTestGate()
        let done = expectation(description: "Latest storage snapshot published")
        var outputs: [Int] = []
        let refresh = CoalescingRefresh<Int, Int>(
            collect: { input in await gate.collect(input) },
            publish: { output in outputs.append(output); done.fulfill() }
        )
        refresh.request(1)
        await gate.waitUntilStarted()
        for input in 2...100 { refresh.request(input) }
        await gate.release()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(outputs, [100])
        let inputs = await gate.inputs
        XCTAssertEqual(inputs, [1, 100])
    }

    func testPaginationKeepsBoundariesAndGenerationMetadata() {
        let store = ConversationStore()
        defer { store.clearAllForWipe() }
        let id = UUID()
        let messages = (0..<520).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "Synthetic turn \(index)",
                modelContent: "Grounding \(index)",
                generationTokensPerSecond: 12,
                generationModelID: "test-model"
            )
        }
        store.saveConversation(id: id, messages: messages)
        let recent = store.recentMessages(for: id, pageSize: 200)
        XCTAssertTrue(recent.hasMore)
        XCTAssertEqual(recent.messages, Array(messages.suffix(200)))
        XCTAssertEqual(store.olderMessages(for: id, before: 200), Array(messages[120..<320]))
        XCTAssertEqual(store.olderMessages(for: id, before: 400), Array(messages[..<120]))
        XCTAssertTrue(store.olderMessages(for: id, before: 520).isEmpty)
        XCTAssertTrue(store.olderMessages(for: id, before: .max).isEmpty)
        XCTAssertEqual(store.olderMessages(for: id, before: -1), recent.messages)
        XCTAssertTrue(store.recentMessages(for: id, pageSize: -1).messages.isEmpty)
        XCTAssertTrue(store.olderMessages(for: id, before: 0, pageSize: -1).isEmpty)
        XCTAssertFalse(store.recentMessages(for: UUID()).hasMore)
    }
}

private actor RefreshTestGate {
    private(set) var inputs: [Int] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func collect(_ input: Int) async -> Int {
        inputs.append(input)
        if input == 1 {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        return input
    }

    func waitUntilStarted() async {
        if releaseWaiter != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
