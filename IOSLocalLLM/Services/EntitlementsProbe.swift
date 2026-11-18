import Foundation

// Adapted from OnDevice Core (MIT; see LICENSE and Docs/COREAI_COMPARISON.md).
// Read only the executable's declared code-signature entitlement slot. A
// matching byte sequence elsewhere in the binary is not an entitlement.
enum EntitlementsProbe {
    static let privateCloudKey = "com.apple.developer.private-cloud-compute"
    static let increasedMemoryKey = "com.apple.developer.kernel.increased-memory-limit"

    private static let signature: [String: Any] = {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
        return executableEntitlements(in: data)
    }()

    private static let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
    private static let profile: [String: Any] = {
        guard let url = profileURL, let data = try? Data(contentsOf: url),
              let plist = provisioningProfilePlist(in: data) else { return [:] }
        return plist["Entitlements"] as? [String: Any] ?? [:]
    }()

    static func hasEntitlement(_ key: String) -> Bool {
        isGranted(signatureEntitled: signature[key] as? Bool == true,
                  hasEmbeddedProfile: profileURL != nil,
                  profileEntitled: profile[key] as? Bool == true)
    }

    static var isPrivateCloudUsable: Bool { hasEntitlement(privateCloudKey) }

    static func isGranted(signatureEntitled: Bool, hasEmbeddedProfile: Bool, profileEntitled: Bool) -> Bool {
        signatureEntitled && (!hasEmbeddedProfile || profileEntitled)
    }

    static func provisioningProfilePlist(in data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        return try? PropertyListSerialization.propertyList(
            from: data[start.lowerBound..<end.upperBound], options: [], format: nil
        ) as? [String: Any]
    }

    /// Thin, little-endian Mach-O binaries used by iOS and its Simulator.
    /// Unsupported or malformed signatures fail closed. No executable-sized
    /// byte-array copy, symbol scanning, or private Security API is needed.
    static func executableEntitlements(in data: Data) -> [String: Any] {
        func word(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            let bytes = data[offset..<(offset + 4)]
            return (bigEndian ? Array(bytes) : Array(bytes.reversed()))
                .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        guard let magic = word(0), magic == 0xfeedfacf || magic == 0xfeedface,
              let count = word(16), let commandBytes = word(20) else { return [:] }
        var offset = magic == 0xfeedfacf ? 32 : 28
        let commandsEnd = offset + Int(commandBytes)
        guard commandsEnd <= data.count, Int(count) <= Int(commandBytes) / 8 else { return [:] }
        for _ in 0..<count {
            guard offset <= commandsEnd - 8,
                  let command = word(offset), let length = word(offset + 4),
                  length >= 8, Int(length) <= commandsEnd - offset else { return [:] }
            defer { offset += Int(length) }
            guard command == 0x1d else { continue } // LC_CODE_SIGNATURE
            guard length >= 16, let start = word(offset + 8), let size = word(offset + 12) else { return [:] }
            let signatureStart = Int(start)
            let signatureEnd = signatureStart + Int(size)
            guard signatureStart >= commandsEnd, signatureEnd <= data.count,
                  size >= 12, word(signatureStart, bigEndian: true) == 0xfade0cc0,
                  let blobLength = word(signatureStart + 4, bigEndian: true),
                  blobLength >= 12, blobLength <= size,
                  let slots = word(signatureStart + 8, bigEndian: true),
                  Int(slots) <= (Int(blobLength) - 12) / 8 else { return [:] }
            for slot in 0..<Int(slots) {
                let index = signatureStart + 12 + slot * 8
                guard word(index, bigEndian: true) == 5 else { continue } // CSSLOT_ENTITLEMENTS
                guard let relativeOffset = word(index + 4, bigEndian: true),
                      Int(relativeOffset) >= 12 + Int(slots) * 8,
                      Int(relativeOffset) <= Int(blobLength) - 8 else { return [:] }
                let blob = signatureStart + Int(relativeOffset)
                guard word(blob, bigEndian: true) == 0xfade7171,
                      let entitlementLength = word(blob + 4, bigEndian: true),
                      entitlementLength > 8,
                      Int(entitlementLength) <= Int(blobLength) - Int(relativeOffset) else { return [:] }
                let payload = data[(blob + 8)..<(blob + Int(entitlementLength))]
                return (try? PropertyListSerialization.propertyList(
                    from: payload, options: [], format: nil
                )) as? [String: Any] ?? [:]
            }
        }
        return [:]
    }
}
