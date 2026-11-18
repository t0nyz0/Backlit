import XCTest
@testable import Backlit

final class LocalizationResolverTests: XCTestCase {
    func testSystemMatchesOrderedPreferencesAndRegionalVariants() {
        let cases: [([String], AppLanguage)] = [
            (["fr-CA", "en"], .french), (["xx", "ja-JP"], .japanese),
            (["en-GB", "fr"], .english), (["es-MX"], .spanish),
            (["de-AT"], .german), (["ko-KR"], .korean), (["th-TH"], .thai),
            (["pt-PT"], .portugueseBrazil), (["pt_BR"], .portugueseBrazil),
            (["zh-Hant-CN"], .chineseTraditional), (["zh-Hans-TW"], .chineseSimplified),
            (["zh-TW"], .chineseTraditional), (["zh-HK"], .chineseTraditional),
            (["zh-MO"], .chineseTraditional), (["zh-CN"], .chineseSimplified),
            (["zh-SG"], .chineseSimplified), (["zh"], .chineseSimplified),
            (["xx"], .english), ([], .english)
        ]
        for (preferred, expected) in cases {
            XCTAssertEqual(AppLanguage.resolve(preference: "system", preferredLanguages: preferred), expected, preferred.description)
        }
    }
    func testExplicitChoiceAndUnknownStoredValue() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(AppLanguage.resolve(preference: language.rawValue, preferredLanguages: ["ja"]), language)
            XCTAssertFalse(language.nativeName.isEmpty)
        }
        XCTAssertEqual(AppLanguage.resolve(preference: "unknown", preferredLanguages: ["ja"]), .english)
    }
    func testNamedPlaceholdersPreserveReorderingAndLiteralSyntax() {
        XCTAssertEqual(Localization.format("{second} / {first}", arguments: ["first":"one", "second":"two"]), "two / one")
        XCTAssertEqual(Localization.format("{value}: {missing}", arguments:["value":"{missing}"]), "{missing}: {missing}")
        XCTAssertEqual(Localization.placeholders(in: "{first} + {first} = {second}"), ["first", "second"])
        XCTAssertEqual(Localization.match(template:"Output ({value}%).",text:"Output (42%)."), ["value":"42"])
        XCTAssertNil(Localization.match(template:"Output ({value}%).",text:"OutputX42%Y!"))
        XCTAssertNil(Localization.match(template:"{same}/{same}",text:"a/b"))
        XCTAssertEqual(Localization.match(template:"รอ {name}…",text:"รอ 日本語…"), ["name":"日本語"])
    }
    func testDiagnosticArgumentsAreNotTranslatedAsUIKeys() {
        for language in AppLanguage.allCases where language != .english {
            let result = Localization.text("Logo control unavailable: Music", language: language)
            XCTAssertTrue(result.hasSuffix("Music"), language.rawValue)
        }
    }
    func testMissingTextAlwaysFallsBackWithoutChangingMachineStrings() {
        for language in AppLanguage.allCases {
            XCTAssertEqual(Localization.text("unknown.machine.status", language: language), "unknown.machine.status")
        }
    }
}

@MainActor final class LocalizationPreferenceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "local.backlit.tests.localization." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
    func testNewInstallUsesSystemAndLegacyExplicitChoicesSurvive() {
        withDefaults { defaults in
            let fresh = AppModel(demo:true, defaults:defaults, preferredLanguages:{["fr-CA"]})
            XCTAssertEqual(fresh.language,"system"); XCTAssertEqual(fresh.resolvedLanguage,.french)
            XCTAssertTrue(fresh.prepareQuit())
            for code in ["en", "zh-Hant"] {
                defaults.set(code,forKey:"language")
                let existing = AppModel(demo:true,defaults:defaults,preferredLanguages:{["ja"]})
                XCTAssertEqual(existing.language,code); XCTAssertEqual(existing.resolvedLanguage.rawValue,code)
                XCTAssertTrue(existing.prepareQuit())
            }
        }
    }
    func testModelStatusRemainsEnglishForEveryPresentationLanguage() {
        withDefaults { defaults in
            let model = AppModel(demo:true, defaults:defaults, preferredLanguages:{["ja"]})
            for language in AppLanguage.allCases {
                model.language = language.rawValue
                XCTAssertEqual(model.status,"Preview · logo unchanged")
            }
            XCTAssertTrue(model.prepareQuit())
        }
    }
    func testInvalidSavedLanguageHasEnglishPickerWithoutOverwritingPreference() {
        withDefaults { defaults in
            defaults.set("unsupported", forKey: "language")
            let model = AppModel(demo:true, defaults:defaults)
            let selection = SettingsPage(model:model).languageSelection
            XCTAssertEqual(selection.wrappedValue, "en")
            XCTAssertEqual(defaults.string(forKey:"language"), "unsupported")
            selection.wrappedValue = "system"
            XCTAssertEqual(defaults.string(forKey:"language"), "system")
            XCTAssertTrue(model.prepareQuit())
        }
    }
    func testEveryExplicitLanguagePersistsAndSystemCanBeRestored() {
        withDefaults { defaults in
            for language in AppLanguage.allCases {
                let model = AppModel(demo:true,defaults:defaults,preferredLanguages:{["ja"]})
                model.language = language.rawValue
                XCTAssertEqual(defaults.string(forKey:"language"),language.rawValue)
                XCTAssertTrue(model.prepareQuit())
                let reopened = AppModel(demo:true,defaults:defaults,preferredLanguages:{["ja"]})
                XCTAssertEqual(reopened.resolvedLanguage,language)
                reopened.language = "system"
                XCTAssertEqual(reopened.resolvedLanguage,.japanese)
                XCTAssertTrue(reopened.prepareQuit())
            }
        }
    }
    func testCaptureOverrideDoesNotPersistAndSystemRefreshNotifiesOnlyEffectiveChanges() {
        withDefaults { defaults in
            var preferred = ["fr"]
            let model = AppModel(demo:true,defaults:defaults,preferredLanguages:{preferred})
            model.language = "system"
            var callbacks = 0; model.onLanguageChange = { callbacks += 1 }
            model.languageOverride = .english
            XCTAssertEqual(model.resolvedLanguage,.english)
            XCTAssertEqual(defaults.string(forKey:"language"),"system")
            model.languageOverride = nil
            XCTAssertEqual(model.resolvedLanguage,.french)
            preferred = ["de"]; model.refreshPreferredLanguages()
            XCTAssertEqual(model.resolvedLanguage,.german)
            model.refreshPreferredLanguages()
            XCTAssertEqual(callbacks,3)
            model.language = "en"; preferred = ["ko"]; model.refreshPreferredLanguages()
            XCTAssertEqual(model.resolvedLanguage,.english)
            XCTAssertEqual(callbacks,4)
            XCTAssertTrue(model.prepareQuit())
        }
    }
}
