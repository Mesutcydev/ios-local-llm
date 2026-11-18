import CoreGraphics
import XCTest
@testable import IOSLocalLLM

final class DisplayDivisionLayoutTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 80)

    func testFlatDisplayAndUnrelatedRegionsKeepTheWholeContainer() {
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: bounds, avoiding: []), .init())
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: bounds, avoiding: [
            CGRect(x: 390, y: 100, width: 20, height: 200),
            CGRect(x: 400, y: 0, width: 0, height: 80)
        ]), .init())
    }

    func testVerticalFoldKeepsControlsInTheWiderPane() {
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: bounds, avoiding: [
            CGRect(x: 280, y: -40, width: 24, height: 300)
        ]), .init(leading: 304, trailing: 0))
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: bounds, avoiding: [
            CGRect(x: 520, y: -40, width: 24, height: 300)
        ]), .init(leading: 0, trailing: 280))
    }

    func testChangingContainerSizeRecomputesThePreferredPane() {
        let fold = CGRect(x: 280, y: 0, width: 24, height: 300)
        let narrow = CGRect(x: 0, y: 0, width: 450, height: 80)
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: narrow, avoiding: [fold]),
                       .init(leading: 0, trailing: 170))
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: bounds, avoiding: [fold]),
                       .init(leading: 304, trailing: 0))
    }

    func testMultipleRegionsAndAsymmetricContainerBounds() {
        let insetBounds = CGRect(x: 20, y: 0, width: 760, height: 80)
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: insetBounds, avoiding: [
            CGRect(x: 100, y: 0, width: 20, height: 80),
            CGRect(x: 600, y: 0, width: 20, height: 80)
        ]), .init(leading: 100, trailing: 180))
    }

    func testHorizontalFoldAndEmptyContainerDoNotHideControls() {
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: bounds, avoiding: [
            CGRect(x: 0, y: 30, width: 800, height: 20)
        ]), .init())
        XCTAssertEqual(DisplayDivisionInsets.resolve(in: .zero, avoiding: [bounds]), .init())
    }
}
