import Foundation
import Security
import CryptoKit

// Generates (once) and persists a P-256 self-signed TLS certificate + private key
// in the iOS Keychain. Exposes a SecIdentity for NWListener TLS and a SHA-256
// fingerprint ("sha256:<hex>") for the QR pairing payload.
final class BridgeIdentity {
    static let shared = BridgeIdentity()

    private static let certLabel = "com.mesutcydev.ioslocalllm.bridge.cert"
    private static let keyTag    = "com.mesutcydev.ioslocalllm.bridge.privkey"

    private(set) var identity: SecIdentity?
    private(set) var fingerprint: String = ""

    private init() { tryLoad() }

    // MARK: - Public

    func generateIfNeeded() throws {
        guard identity == nil else { return }
        purge()
        let privKey = try generatePrivateKey()
        guard let pubKey = SecKeyCopyPublicKey(privKey) else {
            throw BridgeIdentityError.keyGenerationFailed
        }
        var cfErr: Unmanaged<CFError>?
        guard let pubKeyData = SecKeyCopyExternalRepresentation(pubKey, &cfErr) as Data? else {
            if let cfErr { throw cfErr.takeRetainedValue() as Error }
            throw BridgeIdentityError.keyGenerationFailed
        }
        let tbs  = buildTBS(publicKeyBytes: Array(pubKeyData))
        guard let sigData = SecKeyCreateSignature(
            privKey, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, &cfErr
        ) as Data? else {
            if let cfErr { throw cfErr.takeRetainedValue() as Error }
            throw BridgeIdentityError.certCreationFailed
        }
        let certDER = buildCert(tbs: tbs, signature: Array(sigData))
        guard let cert = SecCertificateCreateWithData(nil, Data(certDER) as CFData) else {
            throw BridgeIdentityError.certCreationFailed
        }
        try storeCert(cert)
        tryLoad()
        guard identity != nil else { throw BridgeIdentityError.identityNotFound }
    }

    // MARK: - Key Generation

    private func generatePrivateKey() throws -> SecKey {
        var cfErr: Unmanaged<CFError>?

        // Prefer Secure Enclave (real device only)
        #if !targetEnvironment(simulator)
        let seAttrs: [CFString: Any] = [
            kSecAttrKeyType:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrTokenID:       kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent:    true,
                kSecAttrLabel:         BridgeIdentity.certLabel,
                kSecAttrApplicationTag: Data(BridgeIdentity.keyTag.utf8),
                kSecAttrAccessible:    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary
        ]
        if let key = SecKeyCreateRandomKey(seAttrs as CFDictionary, &cfErr) { return key }
        cfErr = nil
        #endif

        let swAttrs: [CFString: Any] = [
            kSecAttrKeyType:       kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent:    true,
                kSecAttrLabel:         BridgeIdentity.certLabel,
                kSecAttrApplicationTag: Data(BridgeIdentity.keyTag.utf8),
                kSecAttrAccessible:    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary
        ]
        guard let key = SecKeyCreateRandomKey(swAttrs as CFDictionary, &cfErr) else {
            if let cfErr { throw cfErr.takeRetainedValue() as Error }
            throw BridgeIdentityError.keyGenerationFailed
        }
        return key
    }

    // MARK: - DER Certificate Construction

    private func buildTBS(publicKeyBytes: [UInt8]) -> [UInt8] {
        let ecdsaSHA256 = DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02])
        let ecPublicKey = DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        let prime256v1  = DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let commonName  = DER.oid([0x55, 0x04, 0x03])

        let version  = DER.contextExplicit(tag: 0, DER.integer([0x02]))
        let serial   = DER.integer([0x01])
        let sigAlg   = DER.sequence(ecdsaSHA256)
        let name     = DER.sequence(DER.set(DER.sequence(commonName + DER.utf8String("localcoder"))))
        let validity = DER.sequence(DER.utcTime("250101000000Z") + DER.utcTime("350101000000Z"))
        let spki     = DER.sequence(
            DER.sequence(ecPublicKey + prime256v1) + DER.bitString(publicKeyBytes)
        )
        return DER.sequence(version + serial + sigAlg + name + validity + name + spki)
    }

    private func buildCert(tbs: [UInt8], signature: [UInt8]) -> [UInt8] {
        let sigAlg = DER.sequence(DER.oid([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        return DER.sequence(tbs + sigAlg + DER.bitString(signature))
    }

    // MARK: - Keychain

    private func storeCert(_ cert: SecCertificate) throws {
        let attrs: [CFString: Any] = [
            kSecClass:          kSecClassCertificate,
            kSecValueRef:       cert,
            kSecAttrLabel:      BridgeIdentity.certLabel,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw BridgeIdentityError.keychainError(status)
        }
    }

    private func tryLoad() {
        let query: [CFString: Any] = [
            kSecClass:      kSecClassIdentity,
            kSecAttrLabel:  BridgeIdentity.certLabel,
            kSecReturnRef:  true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return }
        // Verify the returned object really IS a SecIdentity before casting.
        // `as?` can't be used here — for CoreFoundation types it "always
        // succeeds" at compile time — so a corrupted/partial keychain (e.g. a
        // private key whose paired cert was purged) would otherwise force-cast
        // and trap. CFGetTypeID is the correct runtime type check; on mismatch
        // we degrade to "no identity" (generateIfNeeded regenerates) instead of
        // crashing at bridge startup.
        guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else { return }
        let id = result as! SecIdentity
        identity = id

        var certRef: SecCertificate?
        guard SecIdentityCopyCertificate(id, &certRef) == errSecSuccess, let cert = certRef else { return }
        let derData = SecCertificateCopyData(cert) as Data
        let hash = SHA256.hash(data: derData)
        fingerprint = "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    private func purge() {
        SecItemDelete([
            kSecClass:          kSecClassCertificate,
            kSecAttrLabel:      BridgeIdentity.certLabel
        ] as CFDictionary)
        SecItemDelete([
            kSecClass:              kSecClassKey,
            kSecAttrApplicationTag: Data(BridgeIdentity.keyTag.utf8)
        ] as CFDictionary)
    }

    // MARK: - Errors

    enum BridgeIdentityError: LocalizedError {
        case keyGenerationFailed, certCreationFailed, identityNotFound
        case keychainError(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keyGenerationFailed:    return "Failed to generate P-256 key pair"
            case .certCreationFailed:     return "Failed to create self-signed certificate"
            case .identityNotFound:       return "Identity not found in Keychain after storage"
            case .keychainError(let s):   return "Keychain error: \(s)"
            }
        }
    }
}
