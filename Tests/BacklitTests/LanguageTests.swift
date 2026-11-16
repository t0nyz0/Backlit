import XCTest
@testable import Backlit

@MainActor final class LanguageTests: XCTestCase {
    func testEachLanguageSelectsItsOwnTextAndUnknownFallsBackToEnglish() {
        let suite = "local.backlit.test.language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(model.language, "en")
        XCTAssertEqual(model.t("Settings", "設定", "การตั้งค่า"), "Settings")
        model.language = "zh-Hant"
        XCTAssertEqual(model.t("Settings", "設定", "การตั้งค่า"), "設定")
        model.language = "th"
        XCTAssertEqual(model.t("Settings", "設定", "การตั้งค่า"), "การตั้งค่า")
        model.language = "fr"
        XCTAssertEqual(model.t("Settings", "設定", "การตั้งค่า"), "Settings")
        XCTAssertTrue(model.prepareQuit())
    }
    func testThaiSurvivesRelaunch() {
        let suite = "local.backlit.test.language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppModel(demo: true, defaults: defaults)
        first.language = "th"
        XCTAssertTrue(first.prepareQuit())
        let reopened = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(reopened.language, "th")
        XCTAssertEqual(reopened.status, "ตัวอย่าง · โลโก้จริงไม่เปลี่ยน")
        XCTAssertTrue(reopened.prepareQuit())
    }
    func testTextWithoutChineseTranslationStaysEnglishInChinese() {
        let suite = "local.backlit.test.language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        model.language = "zh-Hant"
        XCTAssertEqual(model.t("Quit", th: "ออก"), "Quit")
        XCTAssertEqual(model.display("Typing response is off"), "Typing response is off")
        model.language = "th"
        XCTAssertEqual(model.t("Quit", th: "ออก"), "ออก")
        XCTAssertTrue(model.prepareQuit())
    }
    func testRuntimeMessagesTranslateOnDisplayAndUnknownTextFallsBack() {
        let suite = "local.backlit.test.language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        model.language = "th"
        XCTAssertEqual(model.display(model.typingStatus), "ปิดการตอบสนองการพิมพ์อยู่")
        XCTAssertEqual(model.typingStatus, "Typing response is off")
        XCTAssertEqual(model.display(GlowMode.touch.title), "แทร็คแพด")
        XCTAssertEqual(model.display("Ready for trackpad touch"), "พร้อมรับการแตะแทร็คแพด")
        XCTAssertEqual(model.display("Manual logo brightness: 45%"), "ความสว่างโลโก้: 45%")
        XCTAssertEqual(model.display("Logo control unavailable: Invalid brightness."), "ควบคุมโลโก้ไม่ได้: Invalid brightness.")
        XCTAssertEqual(model.display("Something new"), "Something new")
        XCTAssertTrue(model.prepareQuit())
    }
    func testEveryOptionTitleHasThaiText() {
        let titles = GlowMode.allCases.map(\.title) + MusicResponsePreset.allCases.map(\.title)
            + BatteryChargeStyle.allCases.map(\.title) + BatteryReadyStyle.allCases.map(\.title)
            + MCPAccess.allCases.map(\.title) + LogoShortcutAction.allCases.map(\.title)
            + [AgentState.waiting, .working, .attention].flatMap { [$0.rawValue, $0.rawValue.capitalized] }
        for title in titles { XCTAssertNotNil(ThaiText.messages[title], title) }
    }
    func testLanguageChangeNotifiesOnlyOnRealChange() {
        let suite = "local.backlit.test.language." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        var changes = 0; model.onLanguageChange = { changes += 1 }
        model.language = "th"; model.language = "th"; model.language = "en"
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(model.prepareQuit())
    }
}
