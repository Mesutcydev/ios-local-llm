import Foundation
import Observation
import CryptoKit
import Security

/// A parent-controlled feature lock, not age verification or content moderation.
/// Credentials and retry limits stay in the device-only Keychain. Unlocks last
/// only for the current foreground session.
@MainActor @Observable
final class ImageGenerationParentalControls {
    static let shared = ImageGenerationParentalControls()
    private(set) var isRestricted = false
    private(set) var isSessionUnlocked = false
    private(set) var lastError: String?

    var canGenerate: Bool { !isRestricted || isSessionUnlocked }

    struct Credential: Codable {
        var salt: Data
        var digest: Data
        var failedAttempts = 0
        var blockedUntil: Date?
    }

    @ObservationIgnored private let read: () throws -> Data?
    @ObservationIgnored private let write: (Data?) throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var credential: Credential?

    init(read: @escaping () throws -> Data? = ParentalPINKeychain.read,
         write: @escaping (Data?) throws -> Void = ParentalPINKeychain.write,
         now: @escaping () -> Date = Date.init) {
        self.read = read
        self.write = write
        self.now = now
        do {
            if let data = try read() {
                credential = try JSONDecoder().decode(Credential.self, from: data)
                isRestricted = true
            }
        } catch {
            // Keychain or decoding failure must never open a protected feature.
            isRestricted = true
            lastError = "The parental PIN could not be read. Access remains locked."
        }
    }

    func setPIN(_ pin: String, confirmation: String) -> Bool {
        guard !isRestricted || isSessionUnlocked else {
            lastError = "Enter the current parental PIN before changing it."
            return false
        }
        guard pin == confirmation, pin.count >= 6, pin.count <= 12,
              pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            lastError = "Use matching PINs with 6–12 digits."
            return false
        }
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard result == errSecSuccess else {
            lastError = "Could not securely create the PIN."
            return false
        }
        let record = Credential(salt: salt, digest: Self.digest(pin, salt: salt))
        guard persist(record) else { return false }
        isRestricted = true
        lock()
        return true
    }

    func unlock(pin: String) -> Bool {
        guard isRestricted, var record = credential else {
            lastError = "No readable parental PIN is available."
            return false
        }
        guard record.blockedUntil.map({ $0 <= now() }) ?? true else {
            lastError = "Too many attempts. Try again after five minutes."
            return false
        }
        let candidate = Self.digest(pin, salt: record.salt)
        let matches = zip(candidate, record.digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
            && candidate.count == record.digest.count
        if !matches {
            record.failedAttempts += 1
            if record.failedAttempts >= 5 {
                record.blockedUntil = now().addingTimeInterval(300)
                record.failedAttempts = 0
            }
            guard persist(record) else { return false }
            lastError = "Incorrect parental PIN."
            return false
        }
        record.failedAttempts = 0
        record.blockedUntil = nil
        guard persist(record) else { return false }
        isSessionUnlocked = true
        lastError = nil
        return true
    }

    func lock() { isSessionUnlocked = false }

    @discardableResult
    func removeRestriction() -> Bool {
        guard isSessionUnlocked else {
            lastError = "Enter the parental PIN before removing the restriction."
            return false
        }
        do {
            try write(nil)
            credential = nil
            isRestricted = false
            isSessionUnlocked = false
            lastError = nil
            return true
        } catch {
            lastError = "Could not remove the parental PIN. Access remains restricted."
            return false
        }
    }

    private func persist(_ record: Credential) -> Bool {
        do {
            try write(JSONEncoder().encode(record))
            credential = record
            lastError = nil
            return true
        } catch {
            lastError = "Could not save the parental PIN."
            return false
        }
    }

    private static func digest(_ pin: String, salt: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(pin.utf8), using: SymmetricKey(data: salt)))
    }
}

private enum ParentalPINKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.mesutcydev.ioslocalllm.parental-controls",
         kSecAttrAccount as String: "image-generation"]
    }

    static func read() throws -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    static func write(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return
        }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
