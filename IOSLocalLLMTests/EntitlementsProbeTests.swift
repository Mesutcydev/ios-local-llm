import XCTest
@testable import IOSLocalLLM

final class EntitlementsProbeTests: XCTestCase {
    private func words(_ values: [UInt32], bigEndian: Bool) -> Data {
        var result = Data()
        for value in values {
            let bytes = [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                         UInt8((value >> 8) & 255), UInt8(value & 255)]
            result.append(contentsOf: bigEndian ? bytes : Array(bytes.reversed()))
        }
        return result
    }

    private func executableFixture() throws -> Data {
        let xml = try PropertyListSerialization.data(fromPropertyList: [EntitlementsProbe.privateCloudKey: true],
                                                      format: .xml, options: 0)
        let blob = words([0xfade7171, UInt32(xml.count + 8)], bigEndian: true) + xml
        let signature = words([0xfade0cc0, UInt32(blob.count + 20), 1, 5, 20], bigEndian: true) + blob
        return words([0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0], bigEndian: false)
            + words([0x1d, 16, 48, UInt32(signature.count)], bigEndian: false) + signature
    }

    func testEntitlementDecisionForEverySignatureAndProfileCombination() {
        for signature in [false, true] {
            for hasProfile in [false, true] {
                for profile in [false, true] {
                    XCTAssertEqual(EntitlementsProbe.isGranted(signatureEntitled: signature,
                        hasEmbeddedProfile: hasProfile, profileEntitled: profile),
                        signature && (!hasProfile || profile))
                }
            }
        }
    }

    func testReadsOnlyDeclaredCodeSignatureEntitlementSlot() throws {
        let executable = try executableFixture()
        XCTAssertEqual(EntitlementsProbe.executableEntitlements(in: executable)[EntitlementsProbe.privateCloudKey] as? Bool, true)
        // The same blob in ordinary executable data must not grant anything.
        var embeddedString = executable
        embeddedString.replaceSubrange(32..<36, with: words([0x19], bigEndian: false))
        XCTAssertTrue(EntitlementsProbe.executableEntitlements(in: embeddedString).isEmpty)
        var wrongSlot = executable
        wrongSlot.replaceSubrange(60..<64, with: words([0], bigEndian: true))
        XCTAssertTrue(EntitlementsProbe.executableEntitlements(in: wrongSlot).isEmpty)
    }

    func testEveryTruncatedExecutableFailsClosed() throws {
        let executable = try executableFixture()
        for length in 0..<executable.count {
            XCTAssertTrue(EntitlementsProbe.executableEntitlements(in: Data(executable.prefix(length))).isEmpty,
                          "Truncated binary of length \(length) must be rejected")
        }
    }

    func testOutOfBoundsSignatureAndBlobOffsetsFailClosed() throws {
        for (range, bytes) in [
            (40..<44, words([UInt32.max], bigEndian: false)),
            (44..<48, words([UInt32.max], bigEndian: false)),
            (56..<60, words([UInt32.max], bigEndian: true)),
            (64..<68, words([UInt32.max], bigEndian: true))
        ] {
            var executable = try executableFixture()
            executable.replaceSubrange(range, with: bytes)
            XCTAssertTrue(EntitlementsProbe.executableEntitlements(in: executable).isEmpty)
        }
    }

    func testProfileParserReadsWrappedXMLAndRejectsMalformedData() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: [
            "Entitlements": [EntitlementsProbe.increasedMemoryKey: true]
        ], format: .xml, options: 0)
        let wrapped = Data([0x30, 0x82, 0, 0]) + xml + Data([0, 1])
        let profile = try XCTUnwrap(EntitlementsProbe.provisioningProfilePlist(in: wrapped))
        XCTAssertEqual((profile["Entitlements"] as? [String: Bool])?[EntitlementsProbe.increasedMemoryKey], true)
        XCTAssertNil(EntitlementsProbe.provisioningProfilePlist(in: Data("not a profile".utf8)))
        XCTAssertNil(EntitlementsProbe.provisioningProfilePlist(in: Data("<?xml><plist>".utf8)))
    }

    func testPCCFacadeRefusesAnUnprovisionedBuildBeforeFrameworkUse() async throws {
        try XCTSkipIf(ApplePrivateCloud.isProvisionedForCurrentBuild)
        let expected = ApplePrivateCloud.unavailableError
        if ApplePrivateCloud.isSupportedOnCurrentOS {
            let status = await ApplePrivateCloud.currentStatus()
            XCTAssertEqual(status, .entitlementUnavailable)
            XCTAssertEqual(expected, .notProvisioned)
        }
        let contextSize = await ApplePrivateCloud.contextSize()
        XCTAssertNil(contextSize)
        do {
            _ = try await ApplePrivateCloud.answer(ApplePCCRequest(prompt: "test"))
            XCTFail("Unprovisioned builds must refuse")
        } catch { XCTAssertEqual(error as? ApplePCCError, expected) }
        do {
            for try await _ in await ApplePrivateCloud.stream(ApplePCCRequest(prompt: "test")) {}
            XCTFail("Unprovisioned builds must refuse")
        } catch { XCTAssertEqual(error as? ApplePCCError, expected) }
        ApplePrivateCloud.cancel(UUID())
        ApplePrivateCloud.showLimitIncreaseOptions()
    }
}
