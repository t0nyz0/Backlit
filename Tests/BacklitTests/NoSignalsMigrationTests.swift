import XCTest
@testable import Backlit

@MainActor final class NoSignalsMigrationTests: XCTestCase {
    func testRejectedSavedModeMigratesToBatteryAndPreservesUserSettings() throws {
        let suite = "local.backlit.test.removed-mode." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var battery = BatteryResponseOptions(); battery.pulseMinimum = 0.27
        let batteryData = try JSONEncoder().encode(battery)
        defaults.set("signals", forKey: "mode")
        defaults.set(0.23, forKey: "brightness")
        defaults.set(4.5, forKey: "period")
        defaults.set("punchy", forKey: "music.preset")
        defaults.set(true, forKey: "typing.enabled")
        defaults.set(batteryData, forKey: "battery.response")
        defaults.set("keep", forKey: "unrelated.fixture")
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(model.mode, .battery)
        XCTAssertEqual(defaults.string(forKey: "mode"), "battery")
        XCTAssertEqual(model.brightness, 0.23)
        XCTAssertEqual(model.period, 4.5)
        XCTAssertEqual(model.musicPreset, .punchy)
        XCTAssertTrue(model.typingEnabled)
        XCTAssertEqual(defaults.data(forKey: "battery.response"), batteryData)
        XCTAssertEqual(defaults.string(forKey: "unrelated.fixture"), "keep")
        model.updateBattery(.init(level: 0.41, externalPower: false, activelyCharging: false))
        XCTAssertEqual(model.effectOutput(at: 0), 0.41)
        XCTAssertFalse((model.apiState()["effects"] as? [String] ?? []).contains("Signals"))
        XCTAssertNil(model.apiState()["signal_count"])
        XCTAssertTrue(model.prepareQuit())
        let reopened = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(reopened.mode, .battery)
        XCTAssertEqual(reopened.brightness, 0.23)
        XCTAssertTrue(reopened.prepareQuit())
    }
    func testOnlyTheSixExistingBehaviorsAndBasicAutomationRemain() {
        XCTAssertEqual(Set(GlowMode.allCases.map(\.rawValue)), Set(["steady", "breathe", "battery", "music", "agents", "touch"]))
        XCTAssertNil(GlowMode(rawValue: "signals"))
        XCTAssertNil(GlowMode(rawValue: "focus"))
        for url in ["backlit://signal?category=build&state=active", "backlit://focus", "backlit://mode?name=Signals"] {
            XCTAssertThrowsError(try AutomationCommand(url: URL(string: url)!))
        }
        XCTAssertNoThrow(try AutomationCommand(url: URL(string: "backlit://toggle")!))
        XCTAssertNoThrow(try AutomationCommand(url: URL(string: "backlit://mode?name=Battery")!))
    }
}
