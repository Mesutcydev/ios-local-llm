import XCTest
@testable import IOSLocalLLM

@MainActor
final class ModelStorageRecoveryTests: XCTestCase {
    private func withRoots(_ check: ([URL]) throws -> Void) throws {
        let documents = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Documents")
        let roots = ["LLMModels", "HFModels", "GGUFModels"].map { documents.appendingPathComponent($0) }
        defer { try? FileManager.default.removeItem(at: documents.deletingLastPathComponent()) }
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        try check(roots)
    }

    private func model(in root: URL) throws -> InstalledModelRecord {
        let directory = root.appendingPathComponent("local_test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x47, 0x47, 0x55, 0x46]).write(to: directory.appendingPathComponent("model.gguf"))
        try Data("local/local_test".utf8).write(to: directory.appendingPathComponent(".repoID"))
        return try XCTUnwrap(InstalledModelRegistry.validateDirectory(directory, repoID: "local/local_test"))
    }

    private func replacingURL(_ record: InstalledModelRecord, with url: URL) -> InstalledModelRecord {
        InstalledModelRecord(id: record.id, repoID: record.repoID, displayName: record.displayName,
            localURL: url, engine: record.engine, capabilities: record.capabilities,
            architecture: record.architecture, quantization: record.quantization, parameterCount: record.parameterCount,
            installedAt: record.installedAt, validationState: record.validationState, downloadBytes: record.downloadBytes)
    }

    func testStaleContainerRecoversModelAndRetainsInstallationIdentity() throws {
        try withRoots { roots in
            let record = try model(in: roots[1])
            let stale = replacingURL(record, with: URL(fileURLWithPath: "/old/Container/Documents/HFModels/local_test"))
            let recovered = try XCTUnwrap(InstalledModelRegistry.reanchoredRecord(stale, roots: roots))
            XCTAssertEqual(recovered.localURL.standardizedFileURL.path, record.localURL.standardizedFileURL.path)
            XCTAssertEqual(recovered.id, record.id)
            XCTAssertEqual(recovered.installedAt, record.installedAt)
            XCTAssertEqual(recovered.validationState, .valid)
        }
    }

    func testRecoveryDoesNotGuessAcrossRootsOrUseExternalPaths() throws {
        try withRoots { roots in
            let record = try model(in: roots[1])
            for path in ["/old/Documents/LLMModels/local_test", "/outside/local_test"] {
                XCTAssertNil(InstalledModelRegistry.reanchoredRecord(
                    replacingURL(record, with: URL(fileURLWithPath: path)), roots: roots))
            }
        }
    }

    func testConflictingRepoSidecarIsRejected() throws {
        try withRoots { roots in
            let record = try model(in: roots[1])
            try Data("different/repo".utf8).write(to: record.localURL.appendingPathComponent(".repoID"))
            XCTAssertNil(InstalledModelRegistry.reanchoredRecord(record, roots: roots))
        }
    }

    func testExistingMLXRecordIsRevalidatedAfterWeightsDisappear() throws {
        try withRoots { roots in
            let directory = roots[0].appendingPathComponent("model")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, bytes) in [("config.json", Data("{}".utf8)), ("tokenizer.json", Data("{}".utf8)),
                                  ("model.safetensors", Data([1]))] {
                try bytes.write(to: directory.appendingPathComponent(name))
            }
            let record = try XCTUnwrap(InstalledModelRegistry.validateDirectory(directory, repoID: "test/model"))
            XCTAssertEqual(record.validationState, .valid)
            try FileManager.default.removeItem(at: directory.appendingPathComponent("model.safetensors"))
            XCTAssertEqual(InstalledModelRegistry.reanchoredRecord(record, roots: roots)?.validationState, .missingWeights)
        }
    }

    func testSymlinkEscapesAndSimilarPrefixesAreRejected() throws {
        try withRoots { roots in
            let outside = roots[0].deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let link = roots[0].appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertFalse(ModelStoragePaths.isInside(root: roots[0], link))
            XCTAssertFalse(ModelStoragePaths.isInside(root: roots[0], roots[0].appendingPathExtension("other")))
            XCTAssertFalse(ModelStoragePaths.isInside(root: roots[0], roots[0].appendingPathComponent("../outside")))
            XCTAssertNil(ModelStoragePaths.recoveredModelDirectory(for: link, roots: roots))
        }
    }

    func testNestedGGUFRegistersAsReadyWithoutConfigOrTokenizer() throws {
        try withRoots { roots in
            let directory = roots[1].appendingPathComponent("nested")
            let nested = directory.appendingPathComponent("weights")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data([0x47, 0x47, 0x55, 0x46]).write(to: nested.appendingPathComponent("MODEL.GGUF"))
            let record = try XCTUnwrap(InstalledModelRegistry.validateDirectory(directory, repoID: "test/nested"))
            XCTAssertEqual(record.engine, .llamaCpp)
            XCTAssertEqual(record.validationState, .valid)
        }
    }
}
