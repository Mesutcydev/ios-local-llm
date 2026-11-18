import XCTest
@testable import IOSLocalLLM

final class LocalAPIWorkspaceTests: XCTestCase {
    private let pin = "sha256//" + Data(repeating: 7, count: 32).base64EncodedString()

    func testStoppedListenerNeverInheritsChatReadiness() {
        for model in [LocalAPIWorkspaceActivity.Model.ready, .generating, .loading, .failed] {
            XCTAssertEqual(LocalAPIWorkspaceActivity.resolve(
                listener: .stopped, model: model, isLocal: true, isResident: true
            ), .offline)
        }
    }

    func testReadinessRequiresLocalResidentModelAndRunningListener() {
        XCTAssertEqual(LocalAPIWorkspaceActivity.resolve(
            listener: .running, model: .ready, isLocal: true, isResident: true
        ), .ready)
        XCTAssertEqual(LocalAPIWorkspaceActivity.resolve(
            listener: .running, model: .ready, isLocal: false, isResident: true
        ), .localModelRequired)
        XCTAssertEqual(LocalAPIWorkspaceActivity.resolve(
            listener: .running, model: .ready, isLocal: true, isResident: false
        ), .listening)
        XCTAssertEqual(LocalAPIWorkspaceActivity.resolve(
            listener: .failed, model: .ready, isLocal: true, isResident: true
        ), .listenerFailed)
        XCTAssertEqual(LocalAPIWorkspaceActivity.resolve(
            listener: .running, model: .generating, isLocal: true, isResident: true, isStopping: true
        ), .stopping)
    }

    func testOnlyActiveWorkAnimates() {
        for state in [LocalAPIWorkspaceActivity.starting, .stopping, .loading, .generating] {
            XCTAssertTrue(state.isWorking)
        }
        for state in [LocalAPIWorkspaceActivity.offline, .listening, .ready, .localModelRequired, .listenerFailed, .modelFailed] {
            XCTAssertFalse(state.isWorking)
        }
    }

    func testRecipesKeepHTTPSAndPublicKeyPinForEveryFormat() {
        let setup = LocalAPIClientSetup(host: "192.168.1.7", port: 11434, modelID: "local-model", publicKeyPin: pin)
        XCTAssertTrue(setup.hasValidPin)
        XCTAssertEqual(setup.openAIBaseURL, "https://192.168.1.7:11434/v1")
        XCTAssertEqual(setup.baseURL(for: .anthropic), "https://192.168.1.7:11434")
        XCTAssertEqual(setup.baseURL(for: .ollama), setup.origin)
        for format in LocalAPIClientSetup.Format.allCases {
            let command = setup.example(for: format, apiKey: "example-key")
            XCTAssertTrue(command.contains(#"curl --insecure --pinnedpubkey "$IOS_LOCAL_LLM_TLS_PIN""#))
            XCTAssertTrue(command.contains(LocalAPIClientSetup.shellQuote(pin)))
            XCTAssertFalse(command.contains("http://"))
            XCTAssertTrue(command.contains(#""model":"local-model""#))
        }
    }

    func testRecipesQuoteShellValuesAndEncodeModelIDsAsJSON() throws {
        let model = "org/model'\"\\\n$(touch /tmp/never-run)"
        let key = "test' $HOME\n$(false);" + String(UnicodeScalar(96)) + "false" + String(UnicodeScalar(96))
        let setup = LocalAPIClientSetup(host: "192.168.1.7", port: 54321, modelID: model, publicKeyPin: pin)
        for format in LocalAPIClientSetup.Format.allCases {
            let command = setup.example(for: format, apiKey: key)
            XCTAssertTrue(command.contains("export OPENAI_API_KEY=" + LocalAPIClientSetup.shellQuote(key)))
            let quotedBody = try XCTUnwrap(command.components(separatedBy: "  -d ").last)
            let json = String(quotedBody.dropFirst().dropLast()).replacingOccurrences(of: "'\"'\"'", with: "'")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, model)
        }
    }

    func testMissingOrMalformedPinCannotProduceACopyableSetup() {
        for pin in ["", "sha256//", "sha256//not-base64", "sha256//c2hvcnQ=", "sha256:wrong"] {
            let setup = LocalAPIClientSetup(host: "IPHONE_IP", port: 11434, modelID: "local", publicKeyPin: pin)
            XCTAssertFalse(setup.hasValidPin)
            XCTAssertTrue(setup.example(for: .openAI, apiKey: "YOUR_API_KEY").contains("COPY_PIN_FROM_THIS_DEVICE"))
        }
    }

    func testCatalogMatchesImplementedRoutesWithoutAdvertisingUnsupportedAPIs() {
        XCTAssertEqual(Set(LocalAPIClientSetup.routes.map(\.id)), [
            "GET /v1/models", "POST /v1/chat/completions", "POST /v1/responses", "POST /v1/messages",
            "GET /api/tags", "POST /api/show", "POST /api/chat", "POST /api/generate"
        ])
        XCTAssertEqual(LocalAPIClientSetup.routes.count, 8)
    }

    @MainActor
    func testLocalOnlyLoadRefusesMissingWeightsBeforeStartingRuntime() async throws {
        let assistant = CodingAssistantService.shared
        guard assistant.activeExecutionLocation == .localDownloaded,
              !assistant.selectedModelIsInstalled,
              !assistant.isSelectedLocalModelResident else {
            throw XCTSkip("Requires a local model selection without installed weights.")
        }
        let selection = assistant.activeSelectionID
        await assistant.load(allowStorageFallback: false, reselectFromSettings: false, allowDownload: false)
        guard case .failed(let message) = assistant.state else {
            XCTFail("A missing local model must be refused before runtime loading.")
            return
        }
        XCTAssertTrue(message.contains("Download this model in Models"))
        XCTAssertEqual(assistant.activeSelectionID, selection)
        XCTAssertFalse(assistant.isSelectedLocalModelResident)
        await assistant.unloadAndWaitForCleanup()
    }
}
