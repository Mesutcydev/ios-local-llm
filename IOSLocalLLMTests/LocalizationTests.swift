import XCTest
@testable import IOSLocalLLM

final class LocalizationTests: XCTestCase {
    func testEverySupportedLanguageIncludesTheInterfaceCatalog() throws {
        XCTAssertGreaterThan(LocalizationService.interfaceKeys.count, 1_500)
        let token = try NSRegularExpression(pattern: #"\{\{\d+\}\}"#)
        for language in AppLanguage.allCases where language != .system {
            let url = try XCTUnwrap(Bundle.main.url(
                forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                localization: language.rawValue
            ))
            let data = try Data(contentsOf: url)
            let table = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            for key in LocalizationService.interfaceKeys {
                let value = try XCTUnwrap(table[key], "Missing \(language.rawValue): \(key)")
                XCTAssertFalse(value.isEmpty)
                let expected = token.matches(in: key, range: NSRange(key.startIndex..., in: key)).count
                let actual = token.matches(in: value, range: NSRange(value.startIndex..., in: value)).count
                XCTAssertEqual(actual, expected, "Interpolation mismatch in \(language.rawValue): \(key)")
            }
        }
    }

    func testTurkishUsesReviewedNavigationAndSearchLabels() {
        let localization = LocalizationService.shared
        for (source, expected) in [
            ("My Models", "Modellerim"), ("Discover", "Keşfet"),
            ("Search settings", "Ayarlarda ara"), ("Assistant", "Asistan"),
            ("Models & Assistant", "Modeller ve Asistan"), ("Import", "İçe aktar")
        ] {
            XCTAssertEqual(localization.t(source, language: .turkish), expected)
        }
    }

    func testInterpolatedInterfaceValuesRemainVerbatim() {
        let marker = "User_Project-124.swift"
        let localization = LocalizationService.shared
        for language in AppLanguage.allCases where language != .system {
            let translated = localization.t("Delete \(marker)?", language: language)
            XCTAssertTrue(translated.contains(marker), language.rawValue)
            XCTAssertFalse(translated.contains("{{0}}"), language.rawValue)
        }
    }

    func testUnknownContentIsNotTranslated() {
        let content = "Custom document content — Qwen_demo_124"
        for language in AppLanguage.allCases where language != .system {
            XCTAssertEqual(LocalizationService.shared.t(content, language: language), content)
        }
    }

    func testSystemLanguageResolutionIncludesRegionalVariantsAndFallbacks() {
        XCTAssertEqual(LocalizationService.resolve(preferredLanguages: ["tr-TR"]), .turkish)
        XCTAssertEqual(LocalizationService.resolve(preferredLanguages: ["pt-BR"]), .portuguese)
        XCTAssertEqual(LocalizationService.resolve(preferredLanguages: ["zh-Hant-TW"]), .chinese)
        XCTAssertEqual(LocalizationService.resolve(preferredLanguages: ["sv-SE", "ar-SA"]), .arabic)
        XCTAssertEqual(LocalizationService.resolve(preferredLanguages: ["sv-SE"]), .english)
    }
}
