import XCTest
@testable import IOSLocalLLM

final class BridgePairingSecurityTests: XCTestCase {
    @MainActor
    func testQRWithoutValidCertificateCannotReachPairingConfirmation() throws {
        var payload: [String: Any] = ["v": 1, "macHost": "192.168.1.2",
            "pairingPort": 8765, "nonce": "test-nonce", "macName": "Test Mac"]
        func qr() throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        }
        XCTAssertNil(BridgeManager.shared.pendingPairing(from: try qr()))
        payload["macCertFingerprint"] = "sha256:invalid"
        XCTAssertNil(BridgeManager.shared.pendingPairing(from: try qr()))
        payload["macCertFingerprint"] = "sha256:" + String(repeating: "a", count: 64)
        XCTAssertNotNil(BridgeManager.shared.pendingPairing(from: try qr()))
    }

    @MainActor
    func testDirectPairingCallRefusesLegacyQRBeforeStartingServer() async throws {
        let data = try JSONSerialization.data(withJSONObject: ["v": 1,
            "macHost": "192.168.1.2", "pairingPort": 8765,
            "nonce": "test-nonce", "macName": "Test Mac"])
        await BridgeManager.shared.pairWithMac(qrJSON: String(decoding: data, as: UTF8.self))
        guard case .failed(let message) = BridgeManager.shared.pairingPhase else {
            return XCTFail("A legacy QR must be refused")
        }
        XCTAssertTrue(message.contains("Encrypted pairing"))
    }
}
