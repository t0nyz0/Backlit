import XCTest
@testable import Backlit

final class LocalizationCatalogTests: XCTestCase {
    func testEverySupportedLocaleHasCompleteNonemptyCatalogWithMatchingPlaceholders() {
        XCTAssertEqual(Set(LocalizationCatalogs.translations.keys), Set(AppLanguage.allCases.map(\.rawValue)))
        for language in AppLanguage.allCases {
            guard let catalog = LocalizationCatalogs.translations[language.rawValue] else { return XCTFail(language.rawValue) }
            XCTAssertEqual(Set(catalog.keys), LocalizationCatalogs.sourceKeys, language.rawValue)
            for (key, value) in catalog {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language.rawValue): \(key)")
                XCTAssertEqual(Localization.placeholders(in: key), Localization.placeholders(in: value), "\(language.rawValue): \(key)")
            }
        }
    }
    func testNativeBundleLookupMatchesCompiledCatalogAndFallsBackToEnglish() {
        XCTAssertFalse(LocalizationCatalogs.sourceKeys.isEmpty)
        XCTAssertEqual(LocalizationCatalogs.resourceBundle.bundleURL.pathExtension, "bundle")
        for language in AppLanguage.allCases {
            for key in LocalizationCatalogs.sourceKeys {
                XCTAssertEqual(LocalizationCatalogs.localizedString(key, language: language),
                               LocalizationCatalogs.translations[language.rawValue]?[key], "\(language.rawValue): \(key)")
            }
            XCTAssertEqual(LocalizationCatalogs.localizedString("Uncatalogued diagnostic 987", language: language), "Uncatalogued diagnostic 987")
        }
    }
    func testSafetyAndPrivacyMessagesArePresentInEveryLanguage() {
        let keys = [
            "Maximum 30 minutes per closure. Sleep counts toward the timer; relaunching does not reset it. This limit does not guarantee safe temperatures.",
            "Keeps this Mac awake and may leave its built-in screen lit while closed. Limited to 30 minutes; also stops for low battery, heat or Low Power Mode. Keep it on a hard, ventilated surface, never in a bag.",
            "Requires Input Monitoring. Uses timing only; no characters are read or saved. Secure Input can pause this response.",
            "Backlit analyzes system playback locally to make your logo respond to music. No audio is recorded or uploaded.",
            "The current key stops working immediately. Home Assistant will ask for the new key before it can control the light again."
        ]
        for language in AppLanguage.allCases where language != .english {
            for key in keys {
                XCTAssertNotNil(LocalizationCatalogs.translations[language.rawValue]?[key])
                XCTAssertNotEqual(Localization.text(key, language: language), key, language.rawValue)
            }
        }
    }
    func testNewLanguageRecoveryInstructionsNameTheActualRestoreButton() {
        let languages: [AppLanguage] = [.italian, .dutch, .polish, .turkish, .vietnamese, .indonesian]
        let keys = ["A previous session needs restoration. Choose Restore Logo Settings first.",
                    "macOS rejected the logo brightness change. Restore Logo Settings before retrying."]
        for language in languages {
            let button = Localization.text("Restore Light", language: language)
            for key in keys {
                XCTAssertTrue(Localization.text(key, language: language).localizedCaseInsensitiveContains(button), language.rawValue)
            }
        }
    }

    func testCountNeutralSessionTemplatesAndMenuAccessibilityAreLocalized() {
        for language in AppLanguage.allCases where language != .english {
            for key in ["Sessions: {count} · {state}", "Observed sessions: {count} · {state}", "Logo preview, {value} percent", "Last access check: {diagnostic}"] {
                let translated = Localization.text(key, language: language)
                XCTAssertNotEqual(translated, key, "\(language.rawValue): \(key)")
                XCTAssertEqual(Localization.placeholders(in: translated), Localization.placeholders(in: key))
            }
        }
    }
}
