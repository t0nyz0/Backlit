import XCTest
@testable import Backlit

final class BatteryCustomizationTests: XCTestCase {
    func testDefaultOptionsKeepRequestedBehavior() {
        let options = BatteryResponseOptions()
        XCTAssertEqual(options.chargingStyle, .breathe)
        XCTAssertEqual(options.pulsePeriod, 6)
        XCTAssertFalse(options.readyEnabled)
    }
    func testLegacySettingsMigrateWithoutLosingChoices() throws {
        let legacy = Data(#"{"chargingStyle":"steady","readyEnabled":true,"readyThreshold":0.8,"readyStyle":"blink","readyDuration":5}"#.utf8)
        let options = try JSONDecoder().decode(BatteryResponseOptions.self, from: legacy)
        XCTAssertEqual(options.chargingStyle, .steady); XCTAssertEqual(options.pulsePeriod, 6)
        XCTAssertTrue(options.readyEnabled); XCTAssertEqual(options.readyThreshold, 0.8)
        XCTAssertEqual(options.readyStyle, .blink); XCTAssertEqual(options.readyDuration, 5)
        XCTAssertEqual(try JSONDecoder().decode(BatteryResponseOptions.self, from: JSONEncoder().encode(options)), options)
    }
    func testInvalidOrMissingOptionsUseSafeDefaultsAndBounds() throws {
        let invalid = Data(#"{"chargingStyle":"unknown","pulsePeriod":-100,"readyThreshold":3,"readyDuration":1000,"readyStyle":"unknown"}"#.utf8)
        let options = try JSONDecoder().decode(BatteryResponseOptions.self, from: invalid)
        XCTAssertEqual(options.chargingStyle, .breathe); XCTAssertEqual(options.pulsePeriod, 3)
        XCTAssertEqual(options.readyThreshold, 1); XCTAssertEqual(options.readyDuration, 60)
        XCTAssertEqual(options.readyStyle, .pulse); XCTAssertFalse(options.readyEnabled)
        XCTAssertEqual(try JSONDecoder().decode(BatteryResponseOptions.self, from: Data("{}".utf8)), BatteryResponseOptions())
    }
    func testEachChargingStyleAndPulsePeriodActuallyChangeOutput() {
        var input = EffectInput(); input.mode = .battery; input.battery = 0.5; input.brightness = 0.8
        input.externalPower = true; input.activelyCharging = true
        input.batteryChargingStyle = .steady
        XCTAssertEqual(Effects.level(at: 0, input: input), 0.8)
        XCTAssertEqual(Effects.level(at: 3, input: input), 0.8)
        input.batteryChargingStyle = .level
        XCTAssertEqual(Effects.level(at: 0, input: input), 0.4)
        input.batteryChargingStyle = .breathe
        for period in [3.0, 4.5, 6, 10] {
            input.batteryPulsePeriod = period
            XCTAssertEqual(Effects.level(at: 0, input: input), 0.12, accuracy: 0.000001)
            XCTAssertEqual(Effects.level(at: period / 2, input: input), 0.8, accuracy: 0.000001)
        }
        for style in BatteryChargeStyle.allCases {
            input.batteryChargingStyle = style; input.externalPower = false; input.batteryCueLevel = 1
            XCTAssertEqual(Effects.level(at: 3, input: input), 0.4, "Unplugged scaling wins over every charging option and stale cue")
        }
    }
    func testOptionalReadyCueRunsOnceThenReturnsToNormal() {
        var signal = BatteryReadySignal(), options = BatteryResponseOptions()
        options.readyEnabled = true; options.readyDuration = 2
        XCTAssertNil(signal.update(charge: 0.99, externalPower: true, at: 0, options: options))
        XCTAssertNotNil(signal.update(charge: 1, externalPower: true, at: 1, options: options))
        XCTAssertTrue(signal.active); XCTAssertTrue(signal.requiresAnimation)
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 3, options: options))
        XCTAssertFalse(signal.active); XCTAssertFalse(signal.requiresAnimation)
        XCTAssertNil(signal.update(charge: 0.99, externalPower: true, at: 4, options: options))
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 5, options: options))
    }
    func testReadyCueDefaultsOffAndNeverFiresOnOpeningOrSettingsChanges() {
        var signal = BatteryReadySignal(), options = BatteryResponseOptions()
        XCTAssertNil(signal.update(charge: 0.99, externalPower: true, at: 0, options: options))
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 1, options: options))
        options.readyEnabled = true
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 2, options: options))
        signal.reset()
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 3, options: options))
        options.readyThreshold = 0.8
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 4, options: options))
    }
    func testCueCancelsOnUnplugOffOrClockReset() {
        var signal = BatteryReadySignal(), options = BatteryResponseOptions(); options.readyEnabled = true
        _ = signal.update(charge: 0.9, externalPower: true, at: 0, options: options)
        XCTAssertNotNil(signal.update(charge: 1, externalPower: true, at: 1, options: options))
        XCTAssertNil(signal.update(charge: 1, externalPower: false, at: 2, options: options))
        XCTAssertFalse(signal.active)
        XCTAssertNotNil(signal.update(charge: 1, externalPower: true, at: 3, options: options))
        options.readyEnabled = false
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 4, options: options))
        options.readyEnabled = true
        XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 0, options: options))
    }
    func testAllCuePatternsStayBoundedAndBrightnessCapped() {
        for style in BatteryReadyStyle.allCases {
            var signal = BatteryReadySignal(), options = BatteryResponseOptions()
            options.readyEnabled = true; options.readyStyle = style; options.readyDuration = 60
            _ = signal.update(charge: 0.9, externalPower: true, at: 0, options: options)
            for time in stride(from: 1.0, to: 60, by: 0.05) {
                let cue = signal.update(charge: 1, externalPower: true, at: time, options: options)
                XCTAssertNotNil(cue); XCTAssertTrue((0...1).contains(cue ?? -1))
                var input = EffectInput(); input.mode = .battery; input.brightness = 0.3; input.externalPower = true; input.batteryCueLevel = cue
                XCTAssertTrue((0...0.3).contains(Effects.level(at: time, input: input)))
                input.enabled = false; XCTAssertEqual(Effects.level(at: time, input: input), 0)
            }
            XCTAssertNil(signal.update(charge: 1, externalPower: true, at: 61, options: options))
        }
    }
    @MainActor func testEditedOptionsPersistAndResetRestoresDefaultWithoutChangingMode() throws {
        let suite = "local.backlit.test.custom." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("steady", forKey: "mode"); defaults.set(0.4, forKey: "brightness")
        let model = AppModel(demo: true, defaults: defaults)
        model.batteryOptions.chargingStyle = .level; model.batteryOptions.pulsePeriod = 4
        model.batteryOptions.readyEnabled = true; model.batteryOptions.readyThreshold = 0.85
        let reloaded = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(reloaded.batteryOptions, model.batteryOptions)
        model.batteryOptions = BatteryResponseOptions()
        XCTAssertEqual(try JSONDecoder().decode(BatteryResponseOptions.self, from: XCTUnwrap(defaults.data(forKey: "battery.response"))), BatteryResponseOptions())
        XCTAssertEqual(model.mode, .steady); XCTAssertEqual(model.brightness, 0.4)
    }
}
