import XCTest
@testable import IOSLocalLLM

final class WebPrivacyConsentTests: XCTestCase {
    @MainActor
    func testCancellingCallerAlsoCancelsWorkerAndClearsPhase() async {
        let started = expectation(description: "Request started")
        let service = WebToolService(persistSettings: false) { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(60))
            return []
        }
        service.settings.mode = .alwaysAllow
        service.settings.acceptPrivacyDisclosure()
        let request = Task {
            await service.runWebTool(for: .query("fixture"), originalMessage: "fixture")
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        guard case .failure(.cancelled) = await request.value else {
            return XCTFail("Caller cancellation must reach the network worker")
        }
        XCTAssertEqual(service.phase, .idle)
    }

    @MainActor
    func testCancellationDrainsRequestBeforeReturning() async {
        let started = expectation(description: "Request started")
        let service = WebToolService(persistSettings: false) { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(60))
            return []
        }
        service.settings.mode = .alwaysAllow
        service.settings.acceptPrivacyDisclosure()
        let request = Task {
            await service.runWebTool(for: .query("fixture"), originalMessage: "fixture")
        }
        await fulfillment(of: [started], timeout: 2)
        service.cancel()
        await service.cancelAndWait()
        guard case .failure(.cancelled) = await request.value else {
            return XCTFail("Cancellation must drain the worker without publishing context")
        }
        XCTAssertEqual(service.phase, .idle)
    }

    func testLegacyAlwaysAllowRequiresUpdatedDisclosure() throws {
        var settings = WebToolSettings()
        settings.mode = .alwaysAllow
        let data = try JSONEncoder().encode(settings)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "privacyDisclosureVersion")
        json.removeValue(forKey: "privacyDisclosureDestination")
        let restored = try JSONDecoder().decode(WebToolSettings.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.mode, .alwaysAllow)
        XCTAssertEqual(restored.effectiveAccessMode, .askEveryTime)
        if case .requiresPermission = WebToolDecisionEngine().decide(
            message: "https://example.com", settings: restored) {} else {
            XCTFail("An existing preference must not bypass the new disclosure")
        }
    }

    func testChangingProviderOrCustomEndpointRequiresNewDisclosure() {
        var settings = WebToolSettings()
        settings.mode = .alwaysAllow
        settings.acceptPrivacyDisclosure()
        XCTAssertEqual(settings.effectiveAccessMode, .alwaysAllow)
        settings.provider = .custom
        settings.customSearchEndpoint = URL(string: "https://example.com/search")
        XCTAssertEqual(settings.effectiveAccessMode, .askEveryTime)
        settings.acceptPrivacyDisclosure()
        XCTAssertEqual(settings.effectiveAccessMode, .alwaysAllow)
        settings.customSearchEndpoint = URL(string: "https://other.example/search")
        XCTAssertEqual(settings.effectiveAccessMode, .askEveryTime)
        settings.mode = .off
        XCTAssertEqual(settings.effectiveAccessMode, .off)
    }

    @MainActor
    func testServiceRefusesNetworkBeforeDisclosure() async {
        let service = WebToolService.shared
        let original = service.settings
        defer { service.settings = original; service.cancel() }
        service.settings = WebToolSettings()
        service.settings.mode = .alwaysAllow
        let result = await service.runWebTool(for: .url(URL(string: "https://example.com")!),
                                            originalMessage: "example")
        guard case .failure(.permissionDenied) = result else {
            return XCTFail("A direct service call must not bypass consent")
        }
    }
}
