import XCTest

/// Exercises the production page via the existing Debug-only fixture.
/// No model weights or downloads are required; the TLS listener is real.
final class LocalAPIWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(dark: Bool = false, large: Bool = false, screen: String = "api") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-releaseUITestMode", "-localAPIEnabled", "NO", "-uiLanguage", "en",
            "-legalAcceptedVersion", "6", "-aiDisclaimerAccepted", "YES",
            "-deviceSafetyAccepted", "YES", "-hasSeenOnboarding", "YES"
        ]
        app.launchEnvironment["RELEASE_SCREEN"] = screen
        app.launchEnvironment["RELEASE_DARK"] = dark ? "1" : "0"
        app.launchEnvironment["RELEASE_LARGE"] = large ? "1" : "0"
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<16 {
            if element.exists, element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStudioShortcutOpensAPIWorkspaceDirectlyAndReturnsHome() {
        verifyStudioShortcut(dark: false, large: false)
    }

    func testStudioShortcutInDarkModeAndLargeText() {
        verifyStudioShortcut(dark: true, large: true)
    }

    private func verifyStudioShortcut(dark: Bool, large: Bool) {
        let app = launch(dark: dark, large: large, screen: "studio")
        let shortcut = app.buttons["home.api.open"]
        // Home builds its cards lazily: at the largest text size the shortcut
        // does not exist until it is scrolled into view.
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        reveal(shortcut, app: app)
        XCTAssertEqual(shortcut.label, "Local API Server")
        XCTAssertGreaterThanOrEqual(shortcut.frame.height, 44)
        XCTAssertFalse(app.buttons["mac"].exists)
        capture(app, name: dark ? "Studio-API-shortcut-dark-large" : "Studio-API-shortcut-light")
        shortcut.tap()
        XCTAssertTrue(app.buttons["api.server.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["api.server.status"].label, "Server stopped")
        XCTAssertFalse(app.buttons["api.workspace.open"].exists)
        capture(app, name: "Studio-direct-API-workspace")
        app.buttons["api.workspace.close"].tap()
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5))
        reveal(shortcut, app: app)
        XCTAssertTrue(shortcut.isHittable)
    }

    func testStoppedPageExposesSetupWithoutStartingListener() {
        let app = launch()
        XCTAssertTrue(app.buttons["api.server.start"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["api.server.status"].label, "Server stopped")
        let url = app.buttons["api.connection.url"]
        reveal(url, app: app)
        XCTAssertTrue(url.value as? String != nil)
        let commands = app.staticTexts["api.setup.commands"]
        reveal(commands, app: app)
        XCTAssertTrue(commands.label.contains("YOUR_API_KEY"))
        XCTAssertTrue(commands.label.contains("--pinnedpubkey"))
        XCTAssertTrue(app.buttons["api.setup.copy"].isEnabled)
        capture(app, name: "API-stopped-pinned-setup")
    }

    func testRealListenerStartRestartStopAndAccurateModelStatus() {
        let app = launch()
        let start = app.buttons["api.server.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        let stop = app.buttons["api.server.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.staticTexts["api.server.status"].label)
        let listening = app.staticTexts["api.server.status"]
        let ready = NSPredicate(format: "label == %@", "Listening · model unloaded")
        expectation(for: ready, evaluatedWith: listening)
        waitForExpectations(timeout: 10)
        capture(app, name: "API-listener-running-no-model")
        app.buttons["api.server.restart"].tap()
        expectation(for: ready, evaluatedWith: listening)
        waitForExpectations(timeout: 10)
        stop.tap()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(listening.label, "Server stopped")
    }

    func testKeyRotationRequiresConfirmationAndBackgroundMasksKey() {
        let app = launch()
        let revealKey = app.buttons["api.key.reveal"]
        XCTAssertTrue(revealKey.waitForExistence(timeout: 10))
        reveal(revealKey, app: app)
        revealKey.tap()
        XCTAssertEqual(revealKey.label, "Hide key")
        app.buttons["api.key.rotate"].tap()
        XCTAssertTrue(app.buttons["Rotate API key"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()
        revealKey.tap()
        XCTAssertEqual(revealKey.label, "Hide key")
        XCUIDevice.shared.press(.home)
        app.activate()
        reveal(revealKey, app: app)
        XCTAssertEqual(revealKey.label, "Reveal key")
    }

    func testPortValidationAndAllSupportedEndpoints() {
        let app = launch()
        let port = app.textFields["api.settings.port"]
        XCTAssertTrue(port.waitForExistence(timeout: 10))
        reveal(port, app: app)
        port.tap()
        let existing = port.value as? String ?? ""
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + "80")
        app.buttons["api.settings.applyPort"].tap()
        XCTAssertTrue(app.staticTexts["api.settings.portError"].waitForExistence(timeout: 3))
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "54123")
        app.buttons["api.settings.applyPort"].tap()
        XCTAssertEqual(port.value as? String, "54123")
        XCTAssertFalse(app.staticTexts["api.settings.portError"].exists)
        app.terminate()
        app.launch()
        let url = app.buttons["api.connection.url"]
        reveal(url, app: app)
        XCTAssertTrue((url.value as? String ?? "").contains(":54123"))
        reveal(port, app: app)
        XCTAssertEqual(port.value as? String, "54123")
        // Restore the simulator's original preference after verifying storage.
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + existing)
        app.buttons["api.settings.applyPort"].tap()
        app.swipeUp()
        let endpoints = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "8 endpoints")).firstMatch
        reveal(endpoints, app: app)
        endpoints.tap()
        let lastRoute = app.staticTexts["POST /api/generate"]
        reveal(lastRoute, app: app)
        XCTAssertTrue(lastRoute.exists)
        XCTAssertTrue(app.staticTexts["POST /v1/responses"].exists)
        capture(app, name: "API-eight-supported-endpoints")
    }

    func testDarkAccessibilityLayoutAndBridgeEntry() {
        let app = launch(dark: true, large: true, screen: "bridge")
        let entry = app.buttons["api.workspace.open"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        reveal(entry, app: app)
        entry.tap()
        XCTAssertTrue(app.buttons["api.server.start"].waitForExistence(timeout: 10))
        capture(app, name: "API-dark-accessibility-type")
        let choose = app.buttons["api.model.choose"]
        reveal(choose, app: app)
        choose.tap()
        XCTAssertTrue(app.staticTexts["Choose API model"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Apple Private Cloud"].exists)
    }
}
