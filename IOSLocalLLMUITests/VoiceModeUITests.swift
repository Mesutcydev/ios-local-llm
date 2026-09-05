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

    func testTranscriptCanResumeFollowingAfterManualScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-voiceUITestMode", "-UITesting", "-mockDuration", "60"]
        app.launchEnvironment["MOCK_TRANSCRIPT"] = String(
            repeating: "A longer local response keeps the transcript scrollable. ", count: 30
        )
        app.launch()
        let transcript = app.descendants(matching: .any)["karaokeTranscript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 8))
        app.scrollViews["karaokeTranscript"].swipeUp()
        let follow = app.buttons["Follow speech"]
        XCTAssertTrue(follow.waitForExistence(timeout: 3))
        follow.tap()
        XCTAssertTrue(follow.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["endButton"].exists)
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


final class ReleaseScreensUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ screen: String, large: Bool = false, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-releaseUITestMode"]
        app.launchEnvironment["RELEASE_SCREEN"] = screen
        app.launchEnvironment["RELEASE_LARGE"] = large ? "1" : "0"
        app.launchEnvironment["RELEASE_DARK"] = dark ? "1" : "0"
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    func testFilterOnlySearchAndPreflight() {
        let app = launch("search")
        XCTAssertTrue(app.buttons["download"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Show model details"].exists)
        capture(app, "search-light")
        app.buttons["download"].tap()
        XCTAssertTrue(app.navigationBars["Before downloading"].waitForExistence(timeout: 5))
        capture(app, "download-preflight")
        reveal(app.buttons["Download model"], in: app)
        capture(app, "download-confirmation")
    }

    func testSearchWithLargeTextAndDarkAppearance() {
        let app = launch("search", large: true, dark: true)
        XCTAssertTrue(app.buttons["download"].waitForExistence(timeout: 10))
        capture(app, "search-large-dark")
        reveal(app.buttons["download"], in: app)
        capture(app, "search-large-actions")
    }

    func testOnboardingHasReachableNext() {
        let app = launch("onboarding", large: true)
        XCTAssertTrue(app.buttons["onboarding.next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.next"].isHittable)
        capture(app, "onboarding-large")
        app.buttons["onboarding.next"].tap()
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.buttons["Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboarding.install"].isHittable)
        reveal(app.buttons["Chat"], in: app)
        capture(app, "setup-goal-picker")
    }

    func testHomeScreenshot() {
        let app = launch("home")
        XCTAssertTrue(app.staticTexts["Studio"].waitForExistence(timeout: 5))
        capture(app, "home-current")
    }
}
