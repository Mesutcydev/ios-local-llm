import XCTest
#if canImport(OnDeviceLAS)
@testable import OnDeviceLAS
#else
@testable import IOSLocalLLM
#endif

/// The picker routing on ForgeSign-class sideload builds keys off the live
/// `application-identifier`. The predicate is pure so the device-only SecTask
/// probe stays testable in the simulator.
final class LASAppIdentityTests: XCTestCase {
    func testMissingIdentifierIsNotConcrete() {
        XCTAssertFalse(LASAppIdentity.isConcreteApplicationIdentifier(nil))
        XCTAssertFalse(LASAppIdentity.isConcreteApplicationIdentifier(""))
        XCTAssertFalse(LASAppIdentity.isConcreteApplicationIdentifier("   "))
    }

    func testWildcardIdentifiersAreNotConcrete() {
        XCTAssertFalse(LASAppIdentity.isConcreteApplicationIdentifier("*"))
        XCTAssertFalse(LASAppIdentity.isConcreteApplicationIdentifier("TEAMID1234.*"))
        XCTAssertFalse(
            LASAppIdentity.isConcreteApplicationIdentifier("TEAMID1234.com.mesutcydev.*")
        )
    }

    func testConcreteIdentifiersAreConcrete() {
        XCTAssertTrue(
            LASAppIdentity.isConcreteApplicationIdentifier("TEAMID1234.com.mesutcydev.ondevicelas")
        )
        XCTAssertTrue(LASAppIdentity.isConcreteApplicationIdentifier("com.mesutcydev.ondevicelas"))
    }
}
