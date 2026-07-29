import Foundation
import Security
import CryptoKit

// MARK: - BridgePinningDelegate
//
// URLSession delegate that pins the Mac's self-signed TLS leaf
// certificate by SHA-256 fingerprint. Mirror of the Mac side's
// InferenceClient pinning (which pins the iPhone the same way) — so the
// iPhone↔Mac agent channel is mutually fingerprint-pinned rather than
// plaintext.
//
// The expected fingerprint arrives out-of-band in the Mac's QR code
// ("sha256:<hex>"), so a man-in-the-middle on the LAN can't present a
// substitute cert: anything whose leaf doesn't hash to the pinned value
// is rejected before any request bytes are sent.
final class BridgePinningDelegate: NSObject, URLSessionDelegate {

    private let expectedFingerprint: String
    /// Set when a handshake was rejected for a pin mismatch, so the
    /// caller can surface a truthful "certificate changed — re-pair"
    /// error instead of URLSession's generic "cancelled".
    private(set) var pinFailed = false

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }

        let leaf: Data?
        if #available(iOS 15, *) {
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
            leaf = chain?.first.map { SecCertificateCopyData($0) as Data }
        } else {
            leaf = SecTrustGetCertificateAtIndex(trust, 0).map { SecCertificateCopyData($0) as Data }
        }
        guard let data = leaf else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }

        let hash = SHA256.hash(data: data)
        let computed = "sha256:" + hash.map { String(format: "%02x", $0) }.joined()

        if computed == expectedFingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            pinFailed = true
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
