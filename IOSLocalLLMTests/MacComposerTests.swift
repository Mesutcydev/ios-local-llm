#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit
import XCTest
@testable import IOSLocalLLM

/// The Mac composer is a UITextView: Return must send, not insert a line
/// break. These drive the interception that makes that true.
@MainActor
final class MacComposerTests: XCTestCase {

    private func makeComposer(
        canSend: Bool,
        onSend: @escaping () -> Void = {}
    ) -> (composer: MacComposerTextView, view: ComposerUITextView) {
        let composer = MacComposerTextView(
            text: .constant("Hello"),
            ink: .label,
            accent: .systemBlue,
            maximumLines: 6,
            canSend: canSend,
            onSend: onSend
        )
        let view = ComposerUITextView()
        view.canSend = canSend
        return (composer, view)
    }

    func testReturnSendsAndSwallowsTheLineBreak() {
        var sends = 0
        let (composer, view) = makeComposer(canSend: true) { sends += 1 }
        let allowed = composer.makeCoordinator().textView(
            view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "\n"
        )
        XCTAssertFalse(allowed)
        XCTAssertEqual(sends, 1)
    }

    func testReturnFallsBackToALineBreakWhenSendingIsBlocked() {
        var sends = 0
        let (composer, view) = makeComposer(canSend: false) { sends += 1 }
        let allowed = composer.makeCoordinator().textView(
            view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "\n"
        )
        XCTAssertTrue(allowed)
        XCTAssertEqual(sends, 0)
    }

    func testTypedTextIsNeverTreatedAsSend() {
        var sends = 0
        let (composer, view) = makeComposer(canSend: true) { sends += 1 }
        let allowed = composer.makeCoordinator().textView(
            view, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementText: "x"
        )
        XCTAssertTrue(allowed)
        XCTAssertEqual(sends, 0)
    }
}
#endif
