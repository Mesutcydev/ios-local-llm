import Foundation
import UIKit
import Darwin

// Top-level coordinator for the LocalCoderBridge server.
// Manages lifecycle (start/stop), nonce rotation, QR payload generation,
// and paired-client bookkeeping.
@MainActor
final class BridgeManager: ObservableObject {

    static let shared = BridgeManager()

    enum ServerState: Equatable {
        case stopped
        case starting
        case running(host: String, port: UInt16)
        case failed(String)
    }

    // State of the Mac-side QR scan + pairing handshake.
    enum PairingPhase: Equatable {
        case idle
        case scanning
        case pairing
        case paired(macName: String)
        case failed(String)
    }

    @Published private(set) var serverState: ServerState = .stopped
    @Published private(set) var pairedClients: [BridgePairingStore.Client] = []
    @Published           var pairingPhase: PairingPhase = .idle

    private let server  = BridgeServer()
    private let bonjour = BonjourPublisher()
    private var currentNonce = ""
    private var nonceIssuedAt: Date?

    /// Pairing QR nonces expire after this many seconds.
    private static let nonceTTL: TimeInterval = 120

    private init() {}

    // MARK: - Lifecycle

    func start() async {
        guard serverState == .stopped else { return }
        serverState = .starting

        do {
            try BridgeIdentity.shared.generateIfNeeded()
            guard let identity = BridgeIdentity.shared.identity else {
                serverState = .failed("No TLS identity"); return
            }
            try await server.start(identity: identity)

            guard let host = wifiIPAddress() else {
                serverState = .failed("No Wi-Fi connection")
                await server.stop(); return
            }

            let port = BridgeServer.port.rawValue
            serverState = .running(host: host, port: port)
            refreshNonce()

            let modelName = CodingAssistantService.shared.activeModel.displayName
            let deviceId  = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            bonjour.publish(
                port:            port,
                deviceId:        deviceId,
                certFingerprint: BridgeIdentity.shared.fingerprint,
                modelName:       modelName
            )
            refreshPairedClients()
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        await server.stop()
        bonjour.stop()
        serverState = .stopped
    }

    // MARK: - Nonce

    func refreshNonce() {
        currentNonce = UUID().uuidString
        nonceIssuedAt = Date()
        rebuildQRJSON()
    }

    /// Called by BridgeServer on the main actor during /v1/pair.
    func verifyAndConsumeNonce(_ nonce: String) -> Bool {
        guard !currentNonce.isEmpty, nonce == currentNonce else { return false }
        if let issued = nonceIssuedAt,
           Date().timeIntervalSince(issued) > Self.nonceTTL {
            currentNonce = ""
            nonceIssuedAt = nil
            return false
        }
        currentNonce = ""   // one-time use
        nonceIssuedAt = nil
        return true
    }

    // MARK: - Pairing Callback

    func onPaired(clientName: String) {
        refreshNonce()           // new nonce for next pairing
        refreshPairedClients()
        ToastCenter.shared.success("\(clientName) paired", detail: "Mac can now send inference requests.")
    }

    // MARK: - Info Response

    func deviceInfoResponse() -> DeviceInfoResponseDTO {
        let model = CodingAssistantService.shared.activeModel
        return DeviceInfoResponseDTO(
            deviceId:         UIDevice.current.identifierForVendor?.uuidString ?? "",
            deviceName:       UIDevice.current.name,
            modelId:          model.id,
            modelDisplayName: model.displayName,
            modelName:        model.displayName,
            modelLoaded:      CodingAssistantService.shared.isModelLoaded,
            busy:             CodingAssistantService.shared.state == .generating,
            version:          Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            contextWindow:    4096
        )
    }

    // MARK: - Paired Clients

    func refreshPairedClients() {
        // Heals keychain state from older builds that could persist
        // multiple rows per Mac. New pairs save deduped already, but
        // any pre-existing dupes get collapsed here on the next UI
        // refresh — keeping the row with a valid Mac bearer so the
        // agent channel stops 401'ing.
        BridgePairingStore.shared.dedupeByClientName()
        pairedClients = BridgePairingStore.shared.clients()
    }

    func forgetAllClients() {
        BridgePairingStore.shared.deleteAll()
        refreshPairedClients()
        ToastCenter.shared.info("All Macs forgotten")
    }

    // MARK: - QR JSON

    private func rebuildQRJSON() {
        guard case .running(let host, let port) = serverState else { return }
        let payload: [String: Any] = [
            "v":               1,
            "deviceId":        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
            "deviceName":      UIDevice.current.name,
            "host":            host,
            "port":            port,
            "certFingerprint": BridgeIdentity.shared.fingerprint,
            "pairingNonce":    currentNonce
        ]
        _ = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    // MARK: - Scan-and-pair (iPhone scans Mac's QR)

    /// Parse the JSON from the Mac's QR code and push this iPhone's server
    /// details to the Mac's pairing endpoint so the Mac can send inference
    /// requests here without any manual IP entry.
    func pairWithMac(qrJSON: String) async {
        guard let data = qrJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MacQRPayload.self, from: data),
              payload.v == 1 else {
            pairingPhase = .failed("Unrecognised QR — scan an iOS Local LLM Mac QR.")
            return
        }

        // Refuse to send the nonce + bearer in cleartext to a Mac that didn't
        // advertise a TLS cert fingerprint, unless the user explicitly opted
        // into insecure pairing. Without TLS + cert pinning a LAN attacker
        // could sniff the bearer mid-handshake and impersonate the Mac.
        if payload.macCertFingerprint == nil && !AppSettings.shared.allowInsecureBridgePairing {
            pairingPhase = .failed("This Mac doesn't support encrypted pairing. Update the iOS Local LLM Mac app, or enable “Allow insecure pairing” in Settings → Mac to continue over your local network.")
            return
        }

        pairingPhase = .pairing

        // Make sure the iPhone server is running so the Mac has something to call.
        if serverState == .stopped { await start() }
        guard case .running(let iphoneHost, let iphonePort) = serverState else {
            pairingPhase = .failed("Could not start the local server. Check Wi-Fi.")
            return
        }

        // Generate a bearer token the Mac will include on every /v1/infer call.
        let token = UUID().uuidString + UUID().uuidString

        // POST the iPhone's reachability details to the Mac's pairing endpoint.
        let body: [String: Any] = [
            "nonce":                payload.nonce,
            "iphoneHost":           iphoneHost,
            "iphonePort":           iphonePort,
            "iphoneName":           UIDevice.current.name,
            "iphoneCertFingerprint": BridgeIdentity.shared.fingerprint,
            "bearerToken":          token
        ]
        // TLS when the Mac advertised a cert fingerprint in its QR;
        // pin that leaf so a LAN MITM can't intercept the nonce/bearer.
        // Legacy plaintext Macs (no fingerprint) still pair over http.
        let scheme = payload.macCertFingerprint != nil ? "https" : "http"
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "\(scheme)://\(payload.macHost):\(payload.pairingPort)/v1/pair") else {
            pairingPhase = .failed("Invalid Mac address in QR.")
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody   = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Pinned session for TLS Macs; the shared session for legacy http.
        let pinDelegate = payload.macCertFingerprint.map { BridgePinningDelegate(expectedFingerprint: $0) }
        let session: URLSession = pinDelegate.map {
            URLSession(configuration: .ephemeral, delegate: $0, delegateQueue: nil)
        } ?? .shared

        do {
            let (data, resp) = try await session.data(for: req)
            let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            if ok {
                // Parse the Mac's response to pick up the agent bearer
                // it minted for us. Falls back to nil for legacy Macs
                // that still return bare `{"ok":true}` — pairing still
                // succeeds, the iPhone just can't initiate /v1/agent
                // calls until that Mac updates.
                let resp = (try? JSONDecoder().decode(MacPairResponse.self, from: data))
                try? BridgePairingStore.shared.save(
                    token:          token,
                    clientName:     payload.macName,
                    macBearerToken: resp?.macBearerToken,
                    macHost:        payload.macHost,
                    macAgentPort:   resp?.agentPort.map(UInt16.init)
                        ?? payload.pairingPort,
                    macCertFingerprint: payload.macCertFingerprint
                )
                refreshPairedClients()
                onPaired(clientName: payload.macName)
                pairingPhase = .paired(macName: payload.macName)
            } else {
                pairingPhase = .failed("Mac rejected the pairing request.")
            }
        } catch {
            pairingPhase = .failed("Could not reach Mac: \(error.localizedDescription)")
        }
    }

    // MARK: - Wi-Fi IP

    private func wifiIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let iface = current.pointee
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  let namePtr = iface.ifa_name,
                  String(cString: namePtr) == "en0" else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            return String(cString: buf)
        }
        return nil
    }
}

// MARK: - Mac QR Payload DTO

/// JSON structure encoded in the QR code displayed by the Mac app.
private struct MacQRPayload: Decodable {
    let v: Int
    let macHost: String
    let pairingPort: UInt16
    let nonce: String
    let macName: String
    /// SHA-256 of the Mac's self-signed TLS leaf cert. Present on Macs
    /// that serve the pairing/agent channel over TLS; absent on legacy
    /// plaintext Macs (we fall back to http for those).
    let macCertFingerprint: String?
}

/// Mac's pair-response body. All non-`ok` fields are optional so the
/// legacy `{"ok":true}` response from older Mac builds still decodes
/// cleanly — pairing succeeds, the iPhone just won't gain agent
/// capabilities against that Mac.
private struct MacPairResponse: Decodable {
    let ok:             Bool
    let macBearerToken: String?
    let macName:        String?
    let agentPort:      Int?
}
