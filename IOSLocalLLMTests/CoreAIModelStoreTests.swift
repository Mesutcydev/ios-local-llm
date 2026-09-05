import XCTest
@testable import IOSLocalLLM

@MainActor
final class CoreAIModelStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var modelRoot: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var store: CoreAIModelStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreAIModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        modelRoot = tempRoot.appendingPathComponent("installed", isDirectory: true)
        defaultsSuiteName = "CoreAIModelStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        store = CoreAIModelStore(modelDirectory: modelRoot, defaults: defaults)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        if let defaults {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
    }

    func testImportRejectsNonAimodelFile() throws {
        let file = tempRoot.appendingPathComponent("notes.txt")
        try Data("not a model".utf8).write(to: file)
        XCTAssertThrowsError(try store.importModel(from: file)) { error in
            XCTAssertEqual(
                (error as? CoreAIModelStoreError),
                .invalidExtension
            )
        }
        XCTAssertEqual(store.installations.count, 0)
    }

    func testImportResolvesNestedResourcesFolder() throws {
        let wrapper = tempRoot.appendingPathComponent("hub-checkout", isDirectory: true)
        let resources = wrapper.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try makeMinimalPack(at: resources, name: "Nested.aimodel")

        try store.importModel(
            from: wrapper,
            preferredID: "test-nested",
            preferredDisplayName: "Nested Pack"
        )

        guard case .ready(_, let manifest) = store.state else {
            return XCTFail("Expected ready state, got \(store.state)")
        }
        XCTAssertEqual(manifest.id, "test-nested")
        XCTAssertEqual(manifest.displayName, "Nested Pack")
        XCTAssertNotNil(store.modelResourcesURL)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.modelResourcesURL!
                    .appendingPathComponent("metadata.json").path
            )
        )
    }

    func testImportResolvesIOSSubtree() throws {
        let wrapper = tempRoot.appendingPathComponent("official", isDirectory: true)
        let ios = wrapper.appendingPathComponent("ios", isDirectory: true)
        try FileManager.default.createDirectory(at: ios, withIntermediateDirectories: true)
        try makeMinimalPack(at: ios, name: "Official.aimodel")

        try store.importModel(
            from: wrapper,
            preferredID: "test-ios",
            preferredDisplayName: "iOS Pack"
        )

        guard case .ready = store.state else {
            return XCTFail("Expected ready state, got \(store.state)")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.modelResourcesURL!
                    .appendingPathComponent("Official.aimodel").path
            )
        )
    }

    func testImportingASecondPackKeepsBothAndPreservesSelection() throws {
        let first = tempRoot.appendingPathComponent("first", isDirectory: true)
        let second = tempRoot.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeMinimalPack(at: first, name: "First.aimodel")
        try makeMinimalPack(at: second, name: "Second.aimodel")

        try store.importModel(
            from: first,
            preferredID: "first-pack",
            preferredDisplayName: "First Pack"
        )
        guard let firstInstall = store.installationURL else {
            return XCTFail("First pack was not installed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstInstall.path))

        try store.importModel(
            from: second,
            preferredID: "second-pack",
            preferredDisplayName: "Second Pack"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstInstall.path))
        XCTAssertEqual(store.installations.map(\.id).sorted(), ["first-pack", "second-pack"])
        XCTAssertEqual(store.manifest?.id, "first-pack")
        try store.selectModel(id: "second-pack")
        XCTAssertEqual(store.manifest?.id, "second-pack")
    }

    func testImportRejectsParentContainingMultipleRuntimeBundles() throws {
        let wrapper = tempRoot.appendingPathComponent("variants", isDirectory: true)
        let first = wrapper.appendingPathComponent("int4", isDirectory: true)
        let second = wrapper.appendingPathComponent("int8", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try makeMinimalPack(at: first, name: "First.aimodel")
        try makeMinimalPack(at: second, name: "Second.aimodel")

        XCTAssertThrowsError(
            try store.importModel(
                from: wrapper,
                preferredID: "ambiguous",
                preferredDisplayName: "Ambiguous"
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                CoreAIModelStoreError.ambiguousBundleRoot.localizedDescription
            )
        }
    }

    func testRefreshRecoversLegacyBroadCatalogInstallation() throws {
        let version = "legacy-lfm"
        let install = modelRoot.appendingPathComponent(version, isDirectory: true)
        let resources = install.appendingPathComponent("resources", isDirectory: true)
        let exactBundle = resources.appendingPathComponent(
            "lfm2_5_2_6b_decode_int8hu_block32_sym",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: exactBundle, withIntermediateDirectories: true)
        try makeMinimalPack(at: exactBundle, name: "Legacy.aimodel")
        let manifest = makeManifest(id: "zoo-lfm25-2.6b", version: version)
        try JSONEncoder().encode(manifest).write(
            to: resources.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        store.refresh()

        XCTAssertEqual(store.installations.map(\.id), ["zoo-lfm25-2.6b"])
        XCTAssertEqual(store.modelResourcesURL?.standardizedFileURL, exactBundle.standardizedFileURL)
    }

    func testPrefixedCustomIdentityCanBeResolved() throws {
        let custom = tempRoot.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try makeMinimalPack(at: custom, name: "Custom.aimodel")
        try store.importModel(
            from: custom,
            preferredID: "coreai:custom/repo",
            preferredDisplayName: "Custom Pack"
        )

        XCTAssertNotNil(store.installedModel(id: "coreai:custom/repo"))
        XCTAssertEqual(store.installedAssistantModels().first?.id, "coreai:custom/repo")
    }

    func testCatalogUtilityPackDoesNotBecomeAnAssistantModel() throws {
        let utility = tempRoot.appendingPathComponent("utility", isDirectory: true)
        try FileManager.default.createDirectory(at: utility, withIntermediateDirectories: true)
        try makeMinimalPack(at: utility, name: "Utility.aimodel")
        try store.importModel(
            from: utility,
            preferredID: "zoo-embeddinggemma-300m",
            preferredDisplayName: "EmbeddingGemma 300M"
        )

        XCTAssertEqual(store.manifest?.capabilities.textGeneration, false)
        XCTAssertTrue(store.installedAssistantModels().isEmpty)
    }

    func testCatalogVisionPackDoesNotBecomeAnAssistantModel() throws {
        let vision = tempRoot.appendingPathComponent("vision", isDirectory: true)
        try FileManager.default.createDirectory(at: vision, withIntermediateDirectories: true)
        try makeMinimalPack(at: vision, name: "Vision.aimodel")
        try store.importModel(
            from: vision,
            preferredID: "zoo-lfm25-vl-450m",
            preferredDisplayName: "LFM2.5 VL 450M"
        )

        XCTAssertEqual(store.manifest?.capabilities.textGeneration, false)
        XCTAssertEqual(store.manifest?.capabilities.imageInput, true)
        XCTAssertTrue(store.installedAssistantModels().isEmpty)
    }

    // MARK: - Helpers

    private func makeMinimalPack(at root: URL, name: String) throws {
        let aimodel = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: aimodel, withIntermediateDirectories: true)
        try Data([0x01, 0x02, 0x03]).write(to: aimodel.appendingPathComponent("main.mlirb"))
        let metadata = """
        {
          "metadata_version": "0.2",
          "kind": "llm",
          "name": "test",
          "assets": {"main": "\(name)"},
          "language": {
            "tokenizer": "test/tokenizer",
            "vocab_size": 128,
            "max_context_length": 128,
            "embedded_tokenizer": true
          }
        }
        """
        try metadata.write(
            to: root.appendingPathComponent("metadata.json"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("tokenizer", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "{}".write(
            to: root.appendingPathComponent("tokenizer/tokenizer.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeManifest(id: String, version: String) -> CoreAIModelManifest {
        CoreAIModelManifest(
            id: id,
            displayName: "Test Pack",
            version: version,
            modelFamily: "test",
            assetPackID: id,
            expectedFiles: [],
            totalDownloadBytes: 3,
            minimumOSVersion: "27.0",
            supportedDeviceFamilies: ["iPhone"],
            supportedArchitectures: ["arm64"],
            contextWindow: 128,
            maximumOutputTokens: 64,
            capabilities: CoreAIModelCapabilities(
                textGeneration: true,
                streaming: true,
                multiTurn: true,
                imageInput: false,
                guidedGeneration: false,
                toolCalling: false,
                reasoning: false,
                concurrentExecution: false
            ),
            tokenizerIdentifier: nil,
            licenseNotice: "Test only"
        )
    }

}
