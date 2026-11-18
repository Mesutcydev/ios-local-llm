import XCTest
import Network
import Security
@testable import IOSLocalLLM

final class LocalAPITransportTests: XCTestCase {
    private final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        let certificate: Data
        init(certificate: Data) { self.certificate = certificate }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let presented = chain.first,
                  (SecCertificateCopyData(presented) as Data) == certificate else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    @MainActor
    func testHTTPSRequiresTrustedIdentityAndBearerAndRejectsPlaintext() async throws {
        try BridgeIdentity.shared.generateIfNeeded()
        let identity = try XCTUnwrap(BridgeIdentity.shared.identity)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        let certificateData = SecCertificateCopyData(try XCTUnwrap(certificate)) as Data
        let server = LocalAPIServer()
        let ready = expectation(description: "TLS listener ready")
        await server.setEventHandler { event in
            if case .ready = event { ready.fulfill() }
        }
        let port = UInt16.random(in: 49_152...60_000)
        try await server.start(port: port, identity: identity)
        await fulfillment(of: [ready], timeout: 5)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration,
                                 delegate: PinnedCertificateDelegate(certificate: certificateData),
                                 delegateQueue: nil)
        let rejectingSession = URLSession(configuration: configuration,
            delegate: PinnedCertificateDelegate(certificate: Data("wrong identity".utf8)), delegateQueue: nil)
        defer { session.invalidateAndCancel(); rejectingSession.invalidateAndCancel() }
        do {
            let url = URL(string: "https://127.0.0.1:\(port)/v1/models")!
            let (_, unauthorized) = try await session.data(from: url)
            XCTAssertEqual((unauthorized as? HTTPURLResponse)?.statusCode, 401)
            var request = URLRequest(url: url)
            request.setValue("Bearer " + LocalAPIKeyStore.key(), forHTTPHeaderField: "Authorization")
            let (_, authorized) = try await session.data(for: request)
            XCTAssertEqual((authorized as? HTTPURLResponse)?.statusCode, 200)

            // Large bodies are served to callers that present the key and dropped otherwise.
            var large = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/v1/unknown")!)
            large.httpMethod = "POST"
            large.httpBody = Data(repeating: 0x20, count: 200_000)
            large.setValue("Bearer " + LocalAPIKeyStore.key(), forHTTPHeaderField: "Authorization")
            let (_, largeAuthorized) = try await session.data(for: large)
            XCTAssertEqual((largeAuthorized as? HTTPURLResponse)?.statusCode, 404)
            large.setValue(nil, forHTTPHeaderField: "Authorization")
            do {
                _ = try await session.data(for: large)
                XCTFail("An oversized request without the key must be dropped")
            } catch {}
            do {
                _ = try await rejectingSession.data(from: url)
                XCTFail("A different certificate must not be accepted")
            } catch {}

            // Raw TCP reaches the listener without ATS masking a cleartext fallback.
            let closed = expectation(description: "Plaintext connection rejected")
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                connection.send(content: Data("GET /v1/models HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                        XCTAssertFalse(String(data: data ?? Data(), encoding: .utf8)?.contains("HTTP/1.1") ?? false)
                        closed.fulfill()
                    }
                })
            }
            connection.start(queue: .global())
            await fulfillment(of: [closed], timeout: 5)
            connection.cancel()
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}
