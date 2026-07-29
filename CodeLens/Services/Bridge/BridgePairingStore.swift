import Foundation
import Security

// Stores bearer tokens for paired Mac clients in the Keychain.
// One item per token; the token is used as the account key.
final class BridgePairingStore {
    static let shared = BridgePairingStore()
    private static let service = "com.codelens.bridge.pairings"
    private init() {}

    /// Three new optional fields landed with the agent channel:
    ///   • `macBearerToken` — bearer the Mac issued to us; we present
    ///     it on outbound `/v1/agent/*` calls back to that Mac.
    ///   • `macHost` / `macAgentPort` — where to send those calls.
    /// All three are optional so Keychain rows written before the
    /// agent feature still decode (Codable defaults them to nil).
    /// Rows missing `macBearerToken` simply can't be used as agent
    /// targets — the UI shows "re-pair to enable agent" in that case.
    struct Client: Codable {
        let token: String
        let clientName: String
        let pairedAt: Date
        var macBearerToken: String? = nil
        var macHost:        String? = nil
        var macAgentPort:   UInt16? = nil
        /// SHA-256 ("sha256:<hex>") of the Mac's self-signed TLS leaf
        /// cert, learned out-of-band from the pairing QR. When present,
        /// outbound /v1/agent calls go over HTTPS pinned to this value;
        /// nil means a legacy plaintext Mac (http fallback).
        var macCertFingerprint: String? = nil
    }

    // MARK: - Write

    func save(
        token: String,
        clientName: String,
        macBearerToken: String? = nil,
        macHost: String? = nil,
        macAgentPort: UInt16? = nil,
        macCertFingerprint: String? = nil
    ) throws {
        // The Mac dedupes paired iPhones by `iphoneName` — when the
        // user re-pairs, the Mac rotates `macBearerToken` and drops
        // the prior row. Mirror that here: any pre-existing keychain
        // row for the same `clientName` (any token) is stale and would
        // make `firstAgentClient()` non-deterministically return a
        // bearer the Mac no longer accepts → 401. Drop them first.
        deleteAll(matchingClientName: clientName)

        let client = Client(
            token:          token,
            clientName:     clientName,
            pairedAt:       Date(),
            macBearerToken: macBearerToken,
            macHost:        macHost,
            macAgentPort:   macAgentPort,
            macCertFingerprint: macCertFingerprint
        )
        let data = try JSONEncoder().encode(client)
        let attrs: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    BridgePairingStore.service,
            kSecAttrAccount:    token,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(attrs as CFDictionary)
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.saveFailed(status) }
    }

    /// Remove every keychain row whose decoded `clientName` matches.
    /// Used by `save` to keep one row per paired Mac.
    private func deleteAll(matchingClientName name: String) {
        for client in clients() where client.clientName == name {
            SecItemDelete([
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: BridgePairingStore.service,
                kSecAttrAccount: client.token
            ] as CFDictionary)
        }
    }

    // MARK: - Lookup

    /// First stored client whose `clientName` matches. Used by the
    /// agent client to pick up Mac connection info + bearer for
    /// outbound calls. Returns nil if no row matches OR the matched
    /// row predates the agent feature (no macBearerToken stored).
    func clientForAgent(named clientName: String) -> Client? {
        clients().first {
            $0.clientName == clientName && $0.macBearerToken != nil
        }
    }

    /// First stored client paired with a usable agent target. Used by
    /// the UI to surface "the Mac you can agent against" when there's
    /// exactly one paired Mac.
    func firstAgentClient() -> Client? {
        clients().first { $0.macBearerToken != nil }
    }

    // MARK: - Read

    func isValid(token: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: BridgePairingStore.service,
            kSecAttrAccount: token,
            kSecReturnData:  false,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func clients() -> [Client] {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: BridgePairingStore.service,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items.compactMap { try? JSONDecoder().decode(Client.self, from: $0) }
    }

    /// Collapse same-`clientName` rows down to the most recent one,
    /// preferring entries that carry a `macBearerToken` (the agent
    /// channel needs it; a row without it is from a legacy build and
    /// can only serve inbound inference). Idempotent. Safe to call on
    /// every UI refresh — does nothing when no dupes exist.
    func dedupeByClientName() {
        let all = clients()
        let grouped = Dictionary(grouping: all, by: { $0.clientName })
        for (_, group) in grouped where group.count > 1 {
            let keep = group
                .sorted {
                    // Prefer rows with a Mac bearer; tie-break on
                    // newest `pairedAt`.
                    if ($0.macBearerToken != nil) != ($1.macBearerToken != nil) {
                        return $0.macBearerToken != nil
                    }
                    return $0.pairedAt > $1.pairedAt
                }
                .first
            for row in group where row.token != keep?.token {
                SecItemDelete([
                    kSecClass:       kSecClassGenericPassword,
                    kSecAttrService: BridgePairingStore.service,
                    kSecAttrAccount: row.token
                ] as CFDictionary)
            }
        }
    }

    // MARK: - Delete

    func deleteAll() {
        SecItemDelete([
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: BridgePairingStore.service
        ] as CFDictionary)
    }

    // MARK: - Errors

    enum PairingError: LocalizedError {
        case saveFailed(OSStatus)
        var errorDescription: String? {
            if case .saveFailed(let s) = self { return "Keychain save failed: \(s)" }
            return nil
        }
    }
}
