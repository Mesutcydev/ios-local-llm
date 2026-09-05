import XCTest
@testable import IOSLocalLLM

final class FunctioningLogicFixTests: XCTestCase {
    func testNormalizedSHA256StripsPrefix() {
        let oid = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        XCTAssertEqual(
            HFHubMetadata.normalizedSHA256(oid),
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        )
    }

    func testNormalizedSHA256RejectsShortDigest() {
        XCTAssertNil(HFHubMetadata.normalizedSHA256("sha256:abc"))
        XCTAssertNil(HFHubMetadata.normalizedSHA256("not-a-hash"))
    }

    func testLinkHeaderCursor() {
        let header = #"<https://huggingface.co/api/models/org/repo/tree/main?recursive=true&cursor=xyz>; rel="next", <https://huggingface.co/api/models/org/repo/tree/main>; rel="first""#
        XCTAssertEqual(HFHubMetadata.nextCursor(fromLinkHeader: header), "xyz")
        XCTAssertNil(HFHubMetadata.nextCursor(fromLinkHeader: nil))
        XCTAssertNil(HFHubMetadata.nextCursor(fromLinkHeader: #"<https://example.com>; rel="prev""#))
    }

    func testGGUFAdmissionRefusesZeroHeadroom() {
        XCTAssertFalse(
            GGUFLoadAdmission.shouldAdmit(
                fileBytes: 2_000_000_000,
                available: 0,
                minimumNeeded: 500_000_000
            )
        )
        XCTAssertFalse(
            GGUFLoadAdmission.shouldAdmit(
                fileBytes: 2_000_000_000,
                available: 100_000_000,
                minimumNeeded: 500_000_000
            )
        )
        XCTAssertTrue(
            GGUFLoadAdmission.shouldAdmit(
                fileBytes: 2_000_000_000,
                available: 800_000_000,
                minimumNeeded: 500_000_000
            )
        )
    }
}
