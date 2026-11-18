import XCTest
@testable import IOSLocalLLM

final class HFHubMetadataTests: XCTestCase {
    func testLFSChecksumNormalization() {
        let digest = String(repeating: "ABCDEF01", count: 8)
        XCTAssertEqual(HFHubMetadata.normalizedSHA256("sha256:" + digest), digest.lowercased())
        XCTAssertEqual(HFHubMetadata.normalizedSHA256(digest), digest.lowercased())
        for invalid in ["sha256:abc", String(repeating: "z", count: 64), String(repeating: "Ｆ", count: 64)] {
            XCTAssertNil(HFHubMetadata.normalizedSHA256(invalid))
        }
    }

    func testNextCursorDecodesQueryAndMatchesWholeRelation() {
        let header = #"<https://example.com?cursor=old>; rel="prev", <https://huggingface.co/api/models/a/b/tree/main?cursor=a%2Bb%3D>; rel="last next""#
        XCTAssertEqual(HFHubMetadata.nextCursor(fromLinkHeader: header), "a+b=")
        XCTAssertNil(HFHubMetadata.nextCursor(fromLinkHeader: #"<https://example.com?cursor=x>; rel="nextish""#))
        XCTAssertNil(HFHubMetadata.nextCursor(fromLinkHeader: #"<https://example.com?cursor=>; rel="next""#))
        XCTAssertNil(HFHubMetadata.nextCursor(fromLinkHeader: nil))
    }

    @MainActor
    func testDownloaderCollectsAllPagesWithoutFollowingLinkHost() async throws {
        var requests: [URL] = []
        let digest = String(repeating: "A", count: 64)
        let manager = HFModelDownloadManager(repoID: "test/model", destination: .temporaryDirectory) { request in
            requests.append(try XCTUnwrap(request.url))
            let isFirst = requests.count == 1
            let entries: [[String: Any]] = isFirst
                ? [["path": "config.json", "type": "file", "size": 2]]
                : [["path": "config.json", "type": "file", "size": 2],
                   ["path": "model.safetensors", "type": "file", "size": 20,
                    "lfs": ["oid": "sha256:" + digest]]]
            let body = try JSONSerialization.data(withJSONObject: entries)
            let headers = isFirst ? ["Link": #"<https://untrusted.example?cursor=page%2B2>; rel="next""#] : [:]
            return (body, try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: 200,
                                                      httpVersion: nil, headerFields: headers)))
        }
        let files = try await manager.fetchFileList()
        XCTAssertEqual(files.map(\.path), ["config.json", "model.safetensors"])
        XCTAssertEqual(files.last?.sha256, digest.lowercased())
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.host == "huggingface.co" && $0.path == "/api/models/test/model/tree/main" })
        let query = try XCTUnwrap(URLComponents(url: requests[1], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "cursor" }?.value, "page+2")
        XCTAssertEqual(query.first { $0.name == "recursive" }?.value, "true")
    }

    @MainActor
    func testRepeatedCursorFailsInsteadOfLooping() async throws {
        var requests = 0
        let manager = HFModelDownloadManager(repoID: "test/model", destination: .temporaryDirectory) { request in
            requests += 1
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Link": #"<https://huggingface.co?cursor=repeat>; rel="next""#])!)
        }
        do {
            _ = try await manager.fetchFileList()
            XCTFail("Repeated cursors must fail")
        } catch {
            XCTAssertEqual((error as NSError).code, -4)
        }
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    func testMalformedLFSChecksumFailsBeforeDownload() async throws {
        let manager = HFModelDownloadManager(repoID: "test/model", destination: .temporaryDirectory) { request in
            (Data(#"[{"path":"model.safetensors","size":20,"lfs":{"oid":"sha256:bad"}}]"#.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await manager.fetchFileList()
            XCTFail("Invalid metadata must not disable integrity checks")
        } catch {
            XCTAssertEqual((error as NSError).code, -5)
        }
    }

    @MainActor
    func testLaterPageHTTPFailureDoesNotReturnPartialListing() async throws {
        var requests = 0
        let manager = HFModelDownloadManager(repoID: "test/model", destination: .temporaryDirectory) { request in
            requests += 1
            return (Data(#"[{"path":"config.json","size":2}]"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: requests == 1 ? 200 : 500,
                        httpVersion: nil, headerFields: ["Link": #"<https://huggingface.co?cursor=next>; rel="next""#])!)
        }
        do {
            _ = try await manager.fetchFileList()
            XCTFail("A partial listing must not mark a model ready")
        } catch {
            XCTAssertEqual((error as NSError).code, 500)
        }
    }

    @MainActor
    func testCancellationBetweenPagesStopsEnumeration() async throws {
        var requests = 0
        var task: Task<[HFModelDownloadManager.HFFileMeta], Error>!
        let manager = HFModelDownloadManager(repoID: "test/model", destination: .temporaryDirectory) { request in
            requests += 1
            task.cancel()
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Link": #"<https://huggingface.co?cursor=next>; rel="next""#])!)
        }
        task = Task { try await manager.fetchFileList() }
        do {
            _ = try await task.value
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 1)
    }
}

final class HFDownloadReadinessTests: XCTestCase {
    @MainActor
    func testMLXFolderNeedsTokenizerAndCustomRuntimeIsDetected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data([1]).write(to: dir.appendingPathComponent("model.safetensors"))
        XCTAssertFalse(HFModelDownloadManager.looksReady(in: dir))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("tokenizer.json"))
        XCTAssertTrue(HFModelDownloadManager.looksReady(in: dir))

        XCTAssertNil(HFModelDownloadManager.customRuntimeModelType(in: dir))
        try Data(#"{"model_type":"prism_hadamard_qwen35","requires_runtime":"runtime/artifact.py"}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        XCTAssertEqual(HFModelDownloadManager.customRuntimeModelType(in: dir), "prism_hadamard_qwen35")
    }

    @MainActor
    func testGGUFRepositoryDownloadsOneVariantAndItsProjector() {
        typealias File = HFModelDownloadManager.HFFileMeta
        func file(_ path: String, _ size: Int64) -> File { File(path: path, name: path, size: size) }
        func picked(_ files: [File]) -> [String] {
            HFModelDownloadManager.selectingOneGGUFVariant(from: files).map(\.path).sorted()
        }
        // The real layout of ggml-org/SmolVLM2-500M-Video-Instruct-GGUF.
        XCTAssertEqual(picked([
            file("README.md", 289),
            file("SmolVLM2-500M-Video-Instruct-Q8_0.gguf", 436_808_704),
            file("SmolVLM2-500M-Video-Instruct-f16.gguf", 820_424_704),
            file("mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf", 108_785_184),
            file("mmproj-SmolVLM2-500M-Video-Instruct-f16.gguf", 199_470_624),
        ]), ["README.md", "SmolVLM2-500M-Video-Instruct-Q8_0.gguf", "mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf"])
        // 4-bit wins over smaller and larger quantizations; split parts stay together.
        XCTAssertEqual(picked([
            file("m-Q2_K.gguf", 1), file("m-Q8_0.gguf", 8),
            file("m-Q4_K_M-00001-of-00002.gguf", 4), file("m-Q4_K_M-00002-of-00002.gguf", 4),
        ]), ["m-Q4_K_M-00001-of-00002.gguf", "m-Q4_K_M-00002-of-00002.gguf"])
        // No known tag: the smallest variant. Non-GGUF repositories are untouched.
        XCTAssertEqual(picked([file("a-f32.gguf", 9), file("a-f16.gguf", 5)]), ["a-f16.gguf"])
        XCTAssertEqual(picked([file("config.json", 1), file("model.safetensors", 2)]),
                       ["config.json", "model.safetensors"])
    }

    func testGGUFLoaderPrefersFourBitThenName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let magic = Data([0x47, 0x47, 0x55, 0x46, 0x03, 0x00])
        for name in ["m-Q2_K.gguf", "m-f16.gguf", "m-Q4_K_M.gguf", "mmproj-m-f16.gguf", "mmproj-m-Q8_0.gguf"] {
            try magic.write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(LocalModelFileValidator.ggufLLM(in: dir)?.lastPathComponent, "m-Q4_K_M.gguf")
        XCTAssertEqual(LocalModelFileValidator.ggufProjector(in: dir)?.lastPathComponent, "mmproj-m-Q8_0.gguf")
    }
}
