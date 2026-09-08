import XCTest
@testable import IOSLocalLLM

// MARK: - InstalledModelRegistryValidationTests
//
// Pins `InstalledModelRegistry.validateDirectory`, the on-disk probe that
// turns a model folder into an authoritative `InstalledModelRecord`. The
// import service and the download manager both treat a standalone GGUF as a
// complete model (GGUF embeds its tokenizer and ships no config.json), so the
// registry must agree or a legitimately-imported GGUF silently vanishes from
// every picker as "not downloaded".

@MainActor
final class InstalledModelRegistryValidationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    private func write(_ name: String, contents: Data, in dir: URL) throws {
        try contents.write(to: dir.appendingPathComponent(name))
    }

    /// A 4-byte file beginning with the `GGUF` magic byte sequence, so
    /// `LocalModelFileValidator.isValidGGUFFile` accepts it.
    private let ggufMagic = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"

    func test_ggufOnlyDirectoryRegistersAsValidLlamaCpp() throws {
        let modelDir = tempDir.appendingPathComponent("qwen-gguf", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try write("qwen-1.5b-instruct-q4_k_m.gguf", contents: ggufMagic, in: modelDir)

        // No config.json — the old code returned nil here.
        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "local/qwen-gguf")

        XCTAssertNotNil(record, "A GGUF-only directory must produce an installed record.")
        XCTAssertEqual(record?.engine, .llamaCpp)
        XCTAssertEqual(record?.validationState, .valid, "GGUF embeds its tokenizer, so it must be ready.")
    }

    func test_ggufDirectoryWithNestedWeightsStillValidates() throws {
        let modelDir = tempDir.appendingPathComponent("nested", isDirectory: true)
        let inner = modelDir.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: inner, withIntermediateDirectories: true)
        try write("model.gguf", contents: ggufMagic, in: inner)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "nested")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .llamaCpp)
        XCTAssertEqual(record?.validationState, .valid)
    }

    func test_mlxDirectoryRegistersAsValidMlx() throws {
        let modelDir = tempDir.appendingPathComponent("mlx-model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        try write("config.json", contents: Data(#"{"architectures":["Qwen2ForCausalLM"]}"#.utf8), in: modelDir)
        try write("tokenizer.json", contents: Data("{}".utf8), in: modelDir)
        try write("model.safetensors", contents: Data(repeating: 0, count: 32), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "mlx-model")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .mlx)
        XCTAssertEqual(record?.validationState, .valid)
    }

    func test_incompleteMlxDirectoryIsNotReady() throws {
        let modelDir = tempDir.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)
        // config.json present but no weights.
        try write("config.json", contents: Data(#"{"architectures":["Qwen2ForCausalLM"]}"#.utf8), in: modelDir)

        let record = InstalledModelRegistry.validateDirectory(modelDir, repoID: "partial")

        XCTAssertNotNil(record)
        XCTAssertEqual(record?.engine, .mlx)
        XCTAssertEqual(record?.validationState, .missingWeights)
    }

    func test_emptyDirectoryReturnsNil() throws {
        let modelDir = tempDir.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true)

        XCTAssertNil(InstalledModelRegistry.validateDirectory(modelDir, repoID: "empty"))
    }
}
