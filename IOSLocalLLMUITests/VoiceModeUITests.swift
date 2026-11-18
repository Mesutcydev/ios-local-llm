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
        // The transcript opens pinned to the newest text, so the manual scroll
        // that stops following is back toward the start: a downward swipe.
        app.scrollViews["karaokeTranscript"].swipeDown()
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


final class AppLaunchGateUITests: XCTestCase {
    func testSharedLinkDoesNotShowKeyboardOverLegalScreen() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-legalAcceptedVersion", "0", "-aiDisclaimerAccepted", "NO",
            "-deviceSafetyAccepted", "NO", "-hasSeenOnboarding", "YES"
        ]
        app.launch()
        let agreement = app.buttons["legal.agree"]
        XCTAssertTrue(agreement.waitForExistence(timeout: 10))
        app.open(try XCTUnwrap(URL(string: "codelens://share?text=Share%20after%20setup")))
        XCTAssertTrue(agreement.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "shared-link-legal-gate"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class ReleaseScreensUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ screen: String, large: Bool = false, dark: Bool = false, language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-releaseUITestMode", "-uiLanguage", language]
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
        for _ in 0..<40 {
            if element.exists && element.isHittable { break }
            // Drag within the visible scroll area. A screen-relative start at
            // 75% can land on the numeric keyboard instead of scrolling the
            // PIN form, so hidden confirmation fields never become reachable.
            let frame = element.exists ? element.frame : .zero
            let navigation = app.navigationBars.firstMatch
            let keyboard = app.keyboards.firstMatch
            let top = (navigation.exists ? navigation.frame.maxY : app.frame.minY + 80) + 16
            let bottom = (keyboard.exists ? keyboard.frame.minY : app.frame.maxY) - 32
            let height = max(44, bottom - top)
            let above = frame.height > 0 && frame.minY < top
            let startY = top + height * (above ? 0.25 : 0.8)
            let endY = top + height * (above ? 0.8 : 0.25)
            let start = app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5, dy: (startY - app.frame.minY) / app.frame.height))
            let end = app.coordinate(withNormalizedOffset: CGVector(
                dx: 0.5, dy: (endY - app.frame.minY) / app.frame.height))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    func testImageParentalLockSurvivesRestart() {
        let app = launch("image")
        let fixturePIN = "246813"
        let newPIN = app.secureTextFields["imageParentalNewPIN"]
        XCTAssertTrue(newPIN.waitForExistence(timeout: 10))
        newPIN.tap()
        newPIN.typeText(fixturePIN)
        let confirmation = app.secureTextFields["imageParentalConfirmPIN"]
        reveal(confirmation, in: app)
        confirmation.tap()
        confirmation.typeText(fixturePIN)
        let hideKeyboard = app.buttons["imageGenerationHideKeyboard"]
        if hideKeyboard.waitForExistence(timeout: 3) { hideKeyboard.tap() }
        let restrict = app.buttons["imageParentalRestrict"]
        reveal(restrict, in: app)
        restrict.tap()
        capture(app, "parental-after-restrict")
        // When the page was dragged with the keyboard up and the keyboard is
        // then hidden, the first tap can be ignored (iOS 27.0 simulator) and a
        // second one locks. Retry once; a lock that never engages still fails.
        let lockedPIN = app.secureTextFields["imageParentalPIN"]
        if !lockedPIN.waitForExistence(timeout: 2), restrict.exists { restrict.tap() }
        XCTAssertTrue(lockedPIN.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["imageGenerationPrompt"].exists)
        capture(app, "image-parental-locked")
        app.terminate()
        app.launch()
        let pin = app.secureTextFields["imageParentalPIN"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        pin.typeText(fixturePIN)
        if hideKeyboard.waitForExistence(timeout: 3) { hideKeyboard.tap() }
        let unlock = app.buttons["imageParentalUnlock"]
        reveal(unlock, in: app)
        unlock.tap()
        XCTAssertTrue(app.buttons["Remove parental restriction"].waitForExistence(timeout: 5))
        capture(app, "image-parental-unlocked")
        let remove = app.buttons["Remove parental restriction"]
        reveal(remove, in: app)
        remove.tap()
        XCTAssertTrue(newPIN.waitForExistence(timeout: 5))
    }

    func testImageModelCanBeDownloadedBeforeEnteringPrompt() {
        let app = launch("image")
        let prompt = app.descendants(matching: .any)["imageGenerationPrompt"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        let download = app.buttons["imageModelDownload-stabilityai/sd-turbo"]
        reveal(download, in: app)
        XCTAssertTrue(download.isEnabled)
        XCTAssertFalse(app.buttons["imageGenerationStart"].isEnabled)
        capture(app, "image-download-before-prompt")

        app.buttons["imageGenerationChooseModel"].tap()
        let select = app.buttons["imageModelSelect-stable-diffusion-v1-5/stable-diffusion-v1-5"]
        reveal(select, in: app)
        select.tap()
        app.navigationBars["Image Models"].buttons["Done"].tap()
        let selectedDownload = app.buttons["imageModelDownload-stable-diffusion-v1-5/stable-diffusion-v1-5"]
        reveal(selectedDownload, in: app)
        XCTAssertTrue(selectedDownload.isEnabled)
        XCTAssertFalse(app.buttons["imageGenerationStart"].isEnabled)
    }

    func testImageModelPickerWithLargeText() {
        let app = launch("image", large: true, dark: true)
        let chooser = app.buttons["imageGenerationChooseModel"]
        reveal(chooser, in: app)
        chooser.tap()
        let download = app.buttons["imageModelDownload-stabilityai/sdxl-turbo"]
        reveal(download, in: app)
        XCTAssertTrue(download.isEnabled)
        capture(app, "image-model-picker-large-dark")
    }

    func testModelsImageCategoryOffersStandaloneDownload() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiLanguage", "en", "-legalAcceptedVersion", "6",
            "-aiDisclaimerAccepted", "YES", "-deviceSafetyAccepted", "YES",
            "-hasSeenOnboarding", "YES"
        ]
        app.launch()
        let models = app.buttons["Models"]
        XCTAssertTrue(models.waitForExistence(timeout: 15))
        models.tap()
        // Models opens on My Models; downloads live under Discover, and each
        // model's download control is in its details sheet.
        app.segmentedControls["modelsDestinationPicker"].buttons["Discover"].tap()
        let imageSection = app.buttons["modelsSection-Image"]
        reveal(imageSection, in: app)
        imageSection.tap()
        let row = app.buttons["models.image.stabilityai/sd-turbo"]
        reveal(row, in: app)
        row.tap()
        let download = app.buttons["imageModelDownload-stabilityai/sd-turbo"]
        reveal(download, in: app)
        XCTAssertTrue(download.isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["imageGenerationPrompt"].firstMatch.exists)
        capture(app, "models-image-download")
    }

    func testImageParentalControlsWithLargeText() {
        let app = launch("image", large: true, dark: true)
        reveal(app.secureTextFields["imageParentalConfirmPIN"], in: app)
        reveal(app.buttons["imageParentalRestrict"], in: app)
        capture(app, "image-parental-large-dark")
    }

    func testVisionPickerOffersBuiltInOCR() {
        let app = launch("vision")
        XCTAssertTrue(app.staticTexts["Text recognition (OCR)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["FastVLM"].exists)
        capture(app, "vision-ocr-picker")
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
        // At the largest text size the pinned Download bar fills the lower
        // third of the screen, so scroll from above it; `reveal` starts its
        // drag on that bar, which does not scroll the page.
        let chat = app.buttons["Chat"]
        for _ in 0..<10 where !chat.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        XCTAssertTrue(chat.isHittable)
        capture(app, "setup-goal-picker")
    }


    func testLegalGateWithLargestTextAndAccessibleReadStates() throws {
        let app = launch("legal", large: true)
        let privacy = app.buttons["legal.document.lock.shield"]
        reveal(privacy, in: app)
        XCTAssertEqual(privacy.value as? String, "Not read")
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait, .textClipped])
        reveal(app.buttons["legal.agree"], in: app)
        XCTAssertFalse(app.buttons["legal.agree"].isEnabled)
        capture(app, "legal-compact-largest-text")
    }

    func testParentalControlsHaveAccessibleTargets() throws {
        let app = launch("image")
        XCTAssertTrue(app.secureTextFields["imageParentalNewPIN"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait, .textClipped]) { [self] issue in
            let detail = issue.detailedDescription + "\n" + (issue.element?.debugDescription ?? "No element supplied")
            let attachment = XCTAttachment(string: detail)
            attachment.name = "accessibility-issue"
            attachment.lifetime = .keepAlways
            add(attachment)
            return false
        }
        capture(app, "parental-compact-accessibility")
    }

    func testTurkishLegalAndDownloadScreens() {
        var app = launch("legal", large: true, language: "tr")
        let privacy = app.buttons["legal.document.lock.shield"]
        reveal(privacy, in: app)
        XCTAssertEqual(privacy.label, "gizlilik politikası")
        XCTAssertEqual(privacy.value as? String, "Okunmadı")
        reveal(app.buttons["legal.agree"], in: app)
        capture(app, "legal-compact-turkish")
        app.terminate()
        app = launch("search", large: true, language: "tr")
        let download = app.buttons["model.download.mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        reveal(download, in: app)
        download.tap()
        XCTAssertTrue(app.navigationBars["İndirmeden önce"].waitForExistence(timeout: 5))
        // The search card remains in the accessibility tree behind the sheet.
        // Scope the repeated model identifier to the presented preflight form.
        let preflight = app.collectionViews["model.downloadPreflight"]
        let compatibility = preflight.descendants(matching: .any)["model.compatibility.mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"].firstMatch
        reveal(compatibility, in: app)
        XCTAssertTrue(["bu iPhone’da çalışır", "bellek sınırına yakın"].contains(compatibility.label))
        capture(app, "preflight-compatibility-turkish")
        reveal(app.buttons["Modeli indir"], in: app)
        capture(app, "preflight-compact-turkish")
    }

    func testHomeScreenshot() {
        let app = launch("home")
        XCTAssertTrue(app.staticTexts["Studio"].waitForExistence(timeout: 5))
        capture(app, "home-current")
    }

    func testHomeOpensModelsAndWithholdsBlockedImagePrompt() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiLanguage", "en", "-legalAcceptedVersion", "6",
            "-aiDisclaimerAccepted", "YES", "-deviceSafetyAccepted", "YES",
            "-hasSeenOnboarding", "YES"
        ]
        app.launch()
        let models = app.buttons["Models"]
        XCTAssertTrue(models.waitForExistence(timeout: 15))
        models.tap()
        XCTAssertTrue(app.descendants(matching: .any)["modelsDestinationPicker"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "models-normal-navigation")
        app.buttons["Home"].tap()
        let studio = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Generate an Image")).firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 5))
        studio.tap()
        let notice = app.staticTexts["imageGenerationSafetyNotice"]
        reveal(notice, in: app)
        capture(app, "image-local-safety-notice")
        let prompt = app.descendants(matching: .any)["imageGenerationPrompt"].firstMatch
        reveal(prompt, in: app)
        prompt.tap()
        prompt.typeText("NSFW portrait")
        let hideKeyboard = app.buttons["imageGenerationHideKeyboard"]
        XCTAssertTrue(hideKeyboard.waitForExistence(timeout: 5))
        hideKeyboard.tap()
        let generate = app.buttons["imageGenerationStart"]
        reveal(generate, in: app)
        generate.tap()
        let refusal = app.staticTexts["Image generation does not support explicit sexual content, exploitation, or graphic abuse. Try a different prompt."].firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Downloading SDXL-Turbo…"].exists)
        capture(app, "image-prompt-refused-before-download")
    }
}
