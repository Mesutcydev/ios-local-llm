import XCTest
@testable import IOSLocalLLM

@MainActor
final class WipeKeychainTests: XCTestCase {

    func test_wipeAll_clearsWebAPIKeys() async {
        KeychainStore.set("test-brave", account: "brave.apiKey")
        KeychainStore.set("test-tavily", account: "tavily.apiKey")
        XCTAssertTrue(KeychainStore.has(account: "brave.apiKey"))
        XCTAssertTrue(KeychainStore.has(account: "tavily.apiKey"))

        let receipt = await WipeAllDataService.wipeAll()

        XCTAssertFalse(KeychainStore.has(account: "brave.apiKey"))
        XCTAssertFalse(KeychainStore.has(account: "tavily.apiKey"))
        XCTAssertGreaterThanOrEqual(receipt.keychainItemsCleared, 2)
    }

    func test_wipeAll_doesNotRestoreUserContentFromLiveStores() async {
        MemoryStore.shared.add("private memory fixture")
        SnippetStore.shared.add(title: "private snippet fixture", body: "fixture prompt")
        AppSettings.shared.iCloudSyncEnabled = true
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let gguf = docs.appendingPathComponent("GGUFModels/wipe-fixture")
        try? FileManager.default.createDirectory(at: gguf, withIntermediateDirectories: true)

        let receipt = await WipeAllDataService.wipeAll()
        ConversationStore.shared.flush()

        XCTAssertGreaterThan(receipt.memoriesDeleted, 0)
        XCTAssertGreaterThan(receipt.snippetsDeleted, 0)
        XCTAssertTrue(MemoryStore.shared.facts.isEmpty)
        XCTAssertTrue(SnippetStore.shared.snippets.isEmpty)
        XCTAssertTrue(WebActivityLogger.shared.entries.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: "memoryFacts.v1"))
        XCTAssertNil(UserDefaults.standard.data(forKey: "promptSnippets.v1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gguf.path))
        XCTAssertFalse(AppSettings.shared.iCloudSyncEnabled)
    }

    func test_wipeAll_clearsHFToken() async {
        _ = HFTokenStore.shared.save("hf_test_token_12345678")
        XCTAssertTrue(HFTokenStore.shared.hasToken)

        let receipt = await WipeAllDataService.wipeAll()

        XCTAssertFalse(HFTokenStore.shared.hasToken)
        XCTAssertGreaterThanOrEqual(receipt.keychainItemsCleared, 1)
    }
}
