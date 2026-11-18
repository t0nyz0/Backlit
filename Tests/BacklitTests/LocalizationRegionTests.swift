import XCTest
@testable import Backlit

@MainActor final class LocalizationRegionTests: XCTestCase {
    private func withModel(region: String, language: String, _ test: (AppModel) -> Void) {
        let suite = "local.backlit.test.locale-region." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(language,forKey:"language")
        let model = AppModel(demo:true, defaults:defaults, preferredLanguages:{["ja-JP"]}, formattingLocale:{Locale(identifier:region)})
        test(model)
        XCTAssertTrue(model.prepareQuit())
    }
    func testEnglishInterfaceKeepsGermanNumberConventions() {
        withModel(region:"de_DE",language:"en") { model in
            XCTAssertEqual(model.resolvedLanguage,.english)
            XCTAssertEqual(model.l("Settings"),"Settings")
            XCTAssertEqual(model.formattedDecimal(6.5),"6,5")
            XCTAssertEqual(model.formattedInteger(12345),"12.345")
            XCTAssertEqual(model.formattedPercent(0.82),0.82.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier:"de_DE"))))
            XCTAssertNotEqual(model.formattedDecimal(6.5),6.5.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier:"en_US"))))
            let before = model.formattedDecimal(6.5)
            model.language = "th"
            XCTAssertEqual(model.formattedDecimal(6.5),before)
            XCTAssertEqual(model.formattingLocale.identifier,"de_DE")
        }
    }
    func testFrenchInterfaceKeepsSwissNumberConventions() {
        withModel(region:"fr_CH",language:"fr") { model in
            XCTAssertEqual(model.resolvedLanguage,.french)
            let swiss = 6.5.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier:"fr_CH")))
            let france = 6.5.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier:"fr_FR")))
            XCTAssertEqual(model.formattedDecimal(6.5),swiss)
            XCTAssertNotEqual(swiss,france, "Fixture must distinguish Swiss region conventions from generic French")
            XCTAssertNotEqual(model.formattedDecimal(6.5),france)
            XCTAssertEqual(model.formattedInteger(12345),12345.formatted(.number.locale(Locale(identifier:"fr_CH"))))
            XCTAssertEqual(model.formattedPercent(0.82),0.82.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier:"fr_CH"))))
            XCTAssertEqual(model.formattingLocale.identifier,"fr_CH")
        }
    }
    func testRegionRefreshDoesNotOverwriteManualLanguage() {
        let suite = "local.backlit.test.locale-region." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("en",forKey:"language")
        var region = Locale(identifier:"de_DE")
        let model = AppModel(demo:true, defaults:defaults, preferredLanguages:{["fr-CH"]}, formattingLocale:{region})
        XCTAssertEqual(model.formattedDecimal(1.5),"1,5")
        region = Locale(identifier:"en_US")
        model.refreshPreferredLanguages()
        XCTAssertEqual(model.formattedDecimal(1.5),"1.5")
        XCTAssertEqual(model.resolvedLanguage,.english)
        XCTAssertEqual(defaults.string(forKey:"language"),"en")
        XCTAssertTrue(model.prepareQuit())
    }
    func testMenuPreviewFormatsPresentationUsingIndependentRegion() {
        let presentation = LightPresentation()
        presentation.level = 0.82
        let region = Locale(identifier:"ar_EG")
        let preview = MenuLidPreview(presentation:presentation,language:.english,formattingLocale:region)
        XCTAssertEqual(preview.accessibilityText,"Logo preview, \(82.formatted(.number.locale(region))) percent")
        presentation.level = 0.25
        XCTAssertEqual(preview.accessibilityText,"Logo preview, \(25.formatted(.number.locale(region))) percent")
    }
}
