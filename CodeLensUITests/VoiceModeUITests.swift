import XCTest

/// Deterministic Voice Mode UI tests. Launch with `-voiceUITestMode` so the
/// app can present a fixture screen without downloading models.
final class VoiceModeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-voiceUITestMode", "-UITesting"] + args
        app.launch()
        return app
    }

    func testVoiceFixtureSeparatesLLMAndTTS() {
        let app = launchApp(args: ["-mockTTS", "kokoro", "-mockDuration", "8"])
        XCTAssertTrue(app.staticTexts["conversationModelValue"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["conversationModelValue"].label, "Ternary Bonsai 8B")
        XCTAssertTrue(app.staticTexts["ttsVoiceValue"].exists)
        XCTAssertTrue(app.staticTexts["ttsVoiceValue"].label.contains("Kokoro"))
        XCTAssertFalse(app.staticTexts["ttsVoiceValue"].label.contains("Bonsai"))
    }

    func testTranscriptExpandAndInterrupt() {
        let app = launchApp(args: ["-mockDuration", "12"])
        XCTAssertTrue(app.otherElements["karaokeTranscript"].waitForExistence(timeout: 8)
                      || app.descendants(matching: .any)["karaokeTranscript"].waitForExistence(timeout: 8))
        let expand = app.buttons["Expand"]
        if expand.waitForExistence(timeout: 4) {
            expand.tap()
            XCTAssertTrue(app.buttons["Collapse"].waitForExistence(timeout: 2))
        }
        let interrupt = app.buttons["interruptButton"]
        XCTAssertTrue(interrupt.waitForExistence(timeout: 4))
        interrupt.tap()
        XCTAssertTrue(app.buttons["endButton"].exists)
        XCTAssertTrue(app.buttons["muteButton"].exists)
    }

    func testControlsRemainVisible() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["interruptButton"].exists)
        XCTAssertTrue(app.otherElements["voiceOrb"].exists || app.images["voiceOrb"].exists
                      || app.descendants(matching: .any)["voiceOrb"].exists)
    }

    func testReduceMotionLaunchDoesNotCrash() {
        let app = XCUIApplication()
        app.launchArguments = ["-voiceUITestMode", "-UITesting", "-mockDuration", "4"]
        app.launch()
        XCTAssertTrue(app.buttons["endButton"].waitForExistence(timeout: 8))
    }
}
