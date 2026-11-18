import XCTest

/// Uses the production tab hierarchy without downloading or running a model.
final class AdaptiveLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(largeText: Bool = false, dark: Bool = false, screen: String = "studio", language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-releaseUITestMode", "-localAPIEnabled", "NO", "-uiLanguage", language,
            "-legalAcceptedVersion", "6", "-aiDisclaimerAccepted", "YES",
            "-deviceSafetyAccepted", "YES", "-hasSeenOnboarding", "YES"
        ]
        app.launchEnvironment["RELEASE_SCREEN"] = screen
        app.launchEnvironment["RELEASE_LARGE"] = largeText ? "1" : "0"
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

    private func selectTab(_ title: String, in app: XCUIApplication) {
        // A model-role button can also be named Assistant / Voice. Match
        // primary navigation, never the similarly named content control.
        let tab = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", title, "modelsSection-\(title)"
        )).firstMatch
        if tab.waitForExistence(timeout: 2), tab.isHittable {
            tab.tap()
            return
        }
        let ids = ["Home": "house", "Assistant": "brain", "Lens": "camera.viewfinder",
                   "Voice": "waveform", "Models": "cube.box"]
        let item = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND elementType != %d", ids[title]!, XCUIElement.ElementType.image.rawValue
        )).firstMatch
        if !item.exists || !item.isHittable {
            let reveal = sidebarReveal(in: app)
            XCTAssertTrue(reveal.waitForExistence(timeout: 10))
            reveal.tap()
        }
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        XCTAssertTrue(item.isHittable)
        item.tap()
    }

    private func sidebarReveal(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ AND NOT (label BEGINSWITH[c] %@)", "sidebar", "Hide"
        )).firstMatch
    }

    func testDraftSurvivesResizingAndTabNavigation() {
        let app = launch()
        selectTab("Assistant", in: app)
        let composer = app.descendants(matching: .any)
            .matching(identifier: "assistant.composer.input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let draft = "Keep this draft while the window changes."
        composer.typeText(draft)
        // XCTest can lose a synthesized keystroke under Simulator load. This
        // scenario verifies retention of the draft that reached the field.
        let enteredDraft = composer.value as? String
        XCTAssertFalse(enteredDraft?.isEmpty ?? true)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, enteredDraft)
        capture(app, "Assistant-draft-landscape")

        // Turning with the keyboard up must leave the composer above it, so
        // the keyboard can still be dismissed and the tabs reached.
        let dismissKeyboard = app.buttons["Dismiss keyboard"]
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: dismissKeyboard)], timeout: 5)
        if app.keyboards.firstMatch.exists { XCTAssertTrue(dismissKeyboard.isHittable) }
        if dismissKeyboard.isHittable { dismissKeyboard.tap() }
        selectTab("Models", in: app)
        selectTab("Assistant", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, enteredDraft)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertEqual(composer.value as? String, enteredDraft)
        capture(app, "Assistant-draft-portrait")
    }

    func testDashboardShortcutAndSheetDismissalWithLargeText() {
        let app = launch(largeText: true)
        let shortcut = app.buttons["home.api.open"]
        let home = app.scrollViews.containing(.button, identifier: "home.settings").firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        for _ in 0..<12 {
            if shortcut.exists, shortcut.isHittable { break }
            home.swipeUp()
        }
        XCTAssertTrue(shortcut.exists)
        XCTAssertTrue(shortcut.isHittable)
        XCTAssertGreaterThanOrEqual(shortcut.frame.height, 44)
        capture(app, "Home-large-text")
        shortcut.tap()
        let close = app.buttons["api.workspace.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        capture(app, "API-sheet-landscape-large-text")
        close.tap()
        for _ in 0..<12 {
            if shortcut.exists, shortcut.isHittable { break }
            home.swipeUp()
        }
        XCTAssertTrue(shortcut.isHittable)
    }

    func testIdleAssistantShowsModelSetupInsteadOfPreparation() {
        let app = launch()
        selectTab("Assistant", in: app)
        let setup = app.buttons["assistant.model.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 15))
        XCTAssertEqual(setup.label, "Choose a model")
        XCTAssertFalse(app.staticTexts["Your on-device model is getting ready."].exists)
        XCTAssertGreaterThanOrEqual(setup.frame.height, 44)
        setup.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        capture(app, "Assistant-explicit-model-setup")
    }

    func testComposerReservesConversationSpaceAboveKeyboard() {
        let app = launch()
        selectTab("Assistant", in: app)
        let input = app.textFields["assistant.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Keep the editor below the conversation.")

        let keyboard = app.keyboards.firstMatch
        let composer = app.otherElements["assistant.composer"].firstMatch
        let conversation = app.scrollViews["assistant.conversation.scroll"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(conversation.exists)
        XCTAssertTrue(input.isHittable)
        XCTAssertFalse(app.buttons["assistant.model.setup"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Runtime status:"
        )).firstMatch.isHittable)
        XCTAssertLessThanOrEqual(conversation.frame.maxY, composer.frame.minY + 1)
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY + 1)
        capture(app, "Assistant-composer-clear-of-conversation-and-keyboard")
    }

    func testModelsRoleTargetsRemainReadableWithLargeText() {
        let app = launch(largeText: true)
        selectTab("Models", in: app)
        // Check the full catalog column; sidebar recovery has its own test.
        let hideSidebar = app.buttons["ToggleSidebar"].firstMatch
        if hideSidebar.exists, hideSidebar.isHittable { hideSidebar.tap() }
        let catalog = app.scrollViews["models.catalog.scroll"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 10))
        for role in ["Assistant", "Lens", "Voice", "Image"] {
            let button = catalog.descendants(matching: .any)
                .matching(identifier: "modelsSection-\(role)").firstMatch
            for _ in 0..<12 {
                if button.exists, button.isHittable { break }
                catalog.swipeUp()
            }
            XCTAssertTrue(button.exists)
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(button.label, role)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        capture(app, "Models-readable-large-text-roles")
    }

    func testModelsLibrarySearchAndPersistentActions() {
        let app = launch()
        selectTab("Models", in: app)
        let library = app.buttons["My Models"]
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        XCTAssertTrue(library.isSelected)
        let input = app.textFields["Search downloaded models…"]
        XCTAssertTrue(input.exists)
        input.tap()
        input.typeText("no-installed-model-matches-this-query")
        XCTAssertTrue(app.staticTexts["No downloaded models found"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["modelsImportButton"].isHittable)
        // Both the field and empty-state recovery offer a clear action.
        app.buttons["Clear search"].firstMatch.tap()
        XCTAssertEqual(input.value as? String, "Search downloaded models…")
        app.buttons["Discover"].tap()
        XCTAssertTrue(app.textFields["Search online · Hugging Face…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Discover"].isSelected)
        capture(app, "Models-discover-library-navigation")
    }

    func testCoreAICatalogShowsPacksAndSimulatorAvailability() {
        let app = launch()
        selectTab("Models", in: app)
        app.buttons["Discover"].tap()
        let scroll = app.scrollViews["models.catalog.scroll"]
        let disclosure = app.buttons["coreai.catalog"]
        for _ in 0..<8 {
            if disclosure.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(disclosure.isHittable)
        disclosure.tap()
        let download = app.buttons["coreai.download.zoo-qwen3-0.6b-official-ios"]
        for _ in 0..<5 {
            if download.exists { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(download.exists)
        XCTAssertFalse(download.isEnabled, "Simulator must not offer an unsupported Core AI download")
        XCTAssertTrue(app.staticTexts["Qwen3 0.6B · Official iOS"].exists)
        capture(app, "CoreAI-catalog-simulator-availability")
    }

    func testLFM3CatalogEntryShowsDownloadDetails() {
        let app = launch()
        selectTab("Models", in: app)
        app.buttons["Discover"].tap()
        let catalog = app.scrollViews["models.catalog.scroll"]
        catalog.buttons["modelsSection-Assistant"].tap()
        let row = catalog.buttons["models.catalog.lfm3-1.7b-gguf"]
        for _ in 0..<8 {
            if row.isHittable { break }
            catalog.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.buttons["models.details.close"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["LFM3 1.7B"].firstMatch.exists)
        capture(app, "Models-LFM3-details")
    }

    func testModelDetailsCloseBeforeOpeningSettings() {
        let app = launch()
        selectTab("Models", in: app)
        app.buttons["Discover"].tap()
        let catalog = app.scrollViews["models.catalog.scroll"]
        catalog.buttons["modelsSection-Assistant"].tap()
        let row = catalog.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "models.catalog."
        )).firstMatch
        for _ in 0..<5 {
            if row.exists, row.isHittable { break }
            catalog.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        row.tap()
        let close = app.buttons["models.details.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        capture(app, "Models-download-details")
        let settings = app.buttons["Model settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertFalse(close.exists)
        done.tap()
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["modelsImportButton"].isHittable)
    }

    func testModelsDownloadsStayReachableFromEmptyLibrary() {
        let app = launch()
        selectTab("Models", in: app)
        let more = app.buttons["models.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()
        app.buttons["models.downloads"].tap()
        let close = app.buttons["models.downloads.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No active downloads"].exists)
        capture(app, "Models-download-center-empty")
        close.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(more.isHittable)
    }

    func testModelsDarkDiscoveryAndVoiceDetails() {
        let app = launch(dark: true)
        selectTab("Models", in: app)
        capture(app, "Models-library-dark")
        app.buttons["Discover"].tap()
        let catalog = app.scrollViews["models.catalog.scroll"]
        catalog.buttons["modelsSection-Voice"].tap()
        let row = app.buttons["modelsVoiceCatalogCard.tts.apple.system"]
        for _ in 0..<5 {
            if row.exists, row.isHittable { break }
            catalog.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        capture(app, "Models-voice-discovery-dark")
        row.tap()
        let close = app.buttons["models.details.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Select"].exists)
        capture(app, "Models-voice-details-dark")
        close.tap()
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
    }

    func testSettingsSearchFindsPrivacyControls() {
        let app = launch(screen: "settings")
        let search = app.searchFields["Search settings"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("parental")
        let category = app.buttons["settings.category.privacyLegal"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.category.voice"].exists)
        capture(app, "Settings-search-parental-controls")
        category.tap()
        XCTAssertTrue(app.staticTexts["On-device & private"].waitForExistence(timeout: 5))
    }

    func testTurkishModelsAndNativeSheetControls() {
        let app = launch(screen: "models", language: "tr")
        XCTAssertTrue(app.buttons["Modellerim"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["İçe aktar"].exists)
        XCTAssertTrue(app.textFields["İndirilen modellerde ara…"].exists)
        app.buttons["Keşfet"].tap()
        let catalog = app.scrollViews["models.catalog.scroll"]
        let assistant = catalog.buttons["modelsSection-Assistant"]
        XCTAssertEqual(assistant.label, "Asistan")
        assistant.tap()
        let row = catalog.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "models.catalog.")).firstMatch
        for _ in 0..<5 {
            if row.exists, row.isHittable { break }
            catalog.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        row.tap()
        XCTAssertTrue(app.buttons["models.details.close"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["models.details.close"].label, "Tamam")
        XCTAssertFalse(app.staticTexts["RECOMMENDED"].exists)
        XCTAssertFalse(app.staticTexts["SMART HANDLING"].exists)
        XCTAssertTrue(app.staticTexts["AKILLI YÖNETİM"].exists)
        capture(app, "Models-Turkish-details")
        app.buttons["Model ayarları"].tap()
        // This Done button is a native SwiftUI literal rather than loc.t(...).
        XCTAssertTrue(app.buttons["Tamam"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Done"].exists)
    }

    func testLanguageSwitchKeepsAssistantDraftAndUpdatesNavigation() {
        let app = launch()
        selectTab("Assistant", in: app)
        let input = app.textFields["assistant.composer.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("My Models")
        let enteredDraft = input.value as? String
        XCTAssertFalse(enteredDraft?.isEmpty ?? true)
        let dismissKeyboard = app.buttons["Dismiss keyboard"]
        if dismissKeyboard.isHittable { dismissKeyboard.tap() }
        selectTab("Home", in: app)
        app.buttons["home.settings"].tap()
        let appearance = app.descendants(matching: .any)
            .matching(identifier: "settings.category.appearance").firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10))
        appearance.tap()
        let picker = app.buttons["settings.language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Türkçe"].tap()
        XCTAssertTrue(app.staticTexts["ARAYÜZ"].firstMatch.waitForExistence(timeout: 5))
        let close = app.buttons["settings.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(close.label, "Tamam")
        close.tap()
        let assistant = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Asistan", "modelsSection-Assistant"
        )).firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        assistant.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, enteredDraft)
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Çalışma zamanı durumu:"
        )).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Not loaded"].exists)
        capture(app, "Assistant-Turkish-live-switch-keeps-draft")
    }

    func testArabicAndJapaneseModelsUseSelectedLanguage() {
        for (language, library) in [("ar", "نماذجي"), ("ja", "マイモデル")] {
            let app = launch(screen: "models", language: language)
            XCTAssertTrue(app.buttons[library].waitForExistence(timeout: 10), language)
            XCTAssertFalse(app.buttons["My Models"].exists)
            capture(app, "Models-localized-\(language)")
            app.terminate()
        }
    }

    func testComposerKeepsPrimaryActionAndToolsReachableWithLargeText() {
        let app = launch(largeText: true, dark: true, screen: "composer")
        let primary = app.buttons["assistant.composer.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, "Send message")
        XCTAssertTrue(primary.isEnabled)
        for identifier in ["assistant.composer.add", "assistant.composer.model", "assistant.composer.dictation"] {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.isHittable, identifier)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        }
        capture(app, "Composer-large-text-dark-send-action")
        primary.tap()
        XCTAssertEqual(primary.label, "Start voice conversation")
        XCTAssertTrue(primary.isEnabled)
    }

    /// Run on an unfolded Duo. Compact-only destinations cover the other tests.
    func testPrimaryRootsCanRevealCollapsedSidebar() throws {
        let app = launch()
        let hide = app.buttons["ToggleSidebar"].firstMatch
        if !hide.waitForExistence(timeout: 2) {
            let reveal = sidebarReveal(in: app)
            guard reveal.waitForExistence(timeout: 5) else {
                throw XCTSkip("This scenario requires the inner-display sidebar.")
            }
            reveal.tap()
        }
        for title in ["Home", "Models", "Voice"] {
            selectTab(title, in: app)
            XCTAssertTrue(hide.waitForExistence(timeout: 10))
            hide.tap()
            let reveal = sidebarReveal(in: app)
            XCTAssertTrue(reveal.waitForExistence(timeout: 10), "\(title) lost the native sidebar reveal control")
            XCTAssertTrue(reveal.isHittable)
            capture(app, "\(title)-sidebar-reveal")
            reveal.tap()
            XCTAssertTrue(hide.waitForExistence(timeout: 10))
        }
    }
}
