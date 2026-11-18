import XCTest
@testable import IOSLocalLLM

final class CoreAICatalogAvailabilityTests: XCTestCase {
    func testDownloadChoicesArePinnedTextPacksWithClearLicenses() {
        let packs = CoreAIZooCatalog.downloadableTextModels
        XCTAssertEqual(packs.count, 15)
        XCTAssertEqual(Set(packs.map(\.id)).count, packs.count)
        for pack in packs {
            XCTAssertTrue(pack.category == .chat || pack.category == .officialRecipe)
            XCTAssertEqual(pack.revision.count, 40)
            XCTAssertTrue(pack.revision.allSatisfy(\.isHexDigit))
            XCTAssertTrue(pack.licenseNotice.hasPrefix("Apache-2.0"))
            XCTAssertFalse(pack.pathPrefix?.isEmpty ?? true)
            XCTAssertGreaterThan(pack.approxDownloadBytes, 0)
        }
    }

    func testUnsupportedRuntimeDoesNotOfferGeneration() {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        XCTAssertNotNil(CoreAIInferenceService.availabilityReason)
        #endif
    }
}
