import XCTest
@testable import Backlit

final class BatteryRequirementTests: XCTestCase {
    let savedLevels = [0.0, 0.25, 0.5, 0.4044426305970149, 0.68, 1.0]

    func testEveryBatteryPercentageIgnoresEverySavedManualBrightness() {
        for manual in savedLevels + [.nan, .infinity, -1, 2] {
            for percent in 0...100 {
                XCTAssertEqual(Effects.percent(Double(percent)/100), percent, "Display percentages must not truncate values such as 58%")
                var input = EffectInput()
                input.mode = .battery; input.brightness = manual; input.battery = Double(percent) / 100
                XCTAssertEqual(Effects.level(at: 0, input: input), Double(percent) / 100,
                               "Battery \(percent)% must remain exact with saved brightness \(manual)")
            }
        }
    }

    @MainActor private func fixture(manual: Double?, legacy: Bool = false,
                                    test: (AppModel, UserDefaults) throws -> Void) rethrows {
        let suite = "local.backlit.test.battery-requirement." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        if let manual { defaults.set(manual, forKey: "brightness") }
        defaults.set("keep", forKey: "unrelated.fixture")
        let legacyOptions = Data(#"{"chargingStyle":"level","readyEnabled":true,"readyStyle":"blink"}"#.utf8)
        if legacy { defaults.set(legacyOptions, forKey: "battery.response") }
        let model = AppModel(demo: true, defaults: defaults)
        defer {
            XCTAssertTrue(model.prepareQuit())
            defaults.removePersistentDomain(forName: suite)
        }
        try test(model, defaults)
        if legacy { XCTAssertEqual(defaults.data(forKey: "battery.response"), legacyOptions) }
        XCTAssertEqual(defaults.string(forKey: "unrelated.fixture"), "keep")
    }

    @MainActor func testDefaultAndMigratedModelPipelinesTrackAllPercentages() {
        for manual in [Double?](arrayLiteral: nil) + savedLevels.map(Optional.some) {
            for legacy in [false, true] {
                fixture(manual: manual, legacy: legacy) { model, defaults in
                    XCTAssertEqual(model.mode, .battery)
                    let originalManual = model.brightness
                    for percent in 0...100 {
                        model.updateBattery(.init(level: Double(percent)/100, externalPower: false, activelyCharging: false))
                        XCTAssertEqual(model.effectOutput(at: Double(percent)), Double(percent)/100)
                        XCTAssertEqual(model.apiState()["battery"] as? Int, percent)
                        XCTAssertEqual(model.brightness, originalManual)
                    }
                    if let manual { XCTAssertEqual(defaults.double(forKey: "brightness"), manual) }
                }
            }
        }
    }

    @MainActor func testDefaultChargingPausedFullAndUnpluggedAreIndependentOfManualLevel() {
        for manual in savedLevels {
            fixture(manual: manual) { model, _ in
                XCTAssertEqual(model.batteryOptions.chargingStyle, .breathe)
                XCTAssertFalse(model.batteryOptions.readyEnabled)
                model.updateBattery(.init(level: 0.62, externalPower: true, activelyCharging: true))
                XCTAssertEqual(model.effectOutput(at: 0), 0.15, accuracy: 0.000001)
                XCTAssertEqual(model.effectOutput(at: 3), 1, accuracy: 0.000001)
                model.updateBattery(.init(level: 0.62, externalPower: true, activelyCharging: false))
                XCTAssertEqual(model.effectOutput(at: 4), 1)
                model.updateBattery(.init(level: 1, externalPower: true, activelyCharging: false))
                XCTAssertEqual(model.effectOutput(at: 5), 1)
                model.updateBattery(.init(level: 0.62, externalPower: false, activelyCharging: false))
                XCTAssertEqual(model.effectOutput(at: 6), 0.62)
                model.updateBattery(.init(level: 0, externalPower: false, activelyCharging: false))
                XCTAssertEqual(model.effectOutput(at: 7), 0)
            }
        }
    }

    @MainActor func testManualModeSwitchingKeepsTheSavedSliderButCannotScaleBattery() {
        for manual in savedLevels {
            fixture(manual: manual) { model, defaults in
                for _ in 0..<5 {
                    model.mode = .steady
                    XCTAssertEqual(model.effectOutput(at: 0), manual)
                    model.mode = .battery
                    model.updateBattery(.init(level: 0.57, externalPower: false, activelyCharging: false))
                    XCTAssertEqual(model.effectOutput(at: 0), 0.57)
                    XCTAssertEqual(defaults.double(forKey: "brightness"), manual)
                }
                model.mode = .steady
                XCTAssertEqual(model.effectOutput(at: 0), manual)
            }
        }
    }

    @MainActor func testActualTickUsesTheBatteryPipelineWithZeroSavedBrightness() {
        fixture(manual: 0) { model, _ in
            model.tick() // Demo samples 82% on battery; no hardware is controlled.
            XCTAssertEqual(model.output, 0.82)
            XCTAssertEqual(model.apiState()["brightness"] as? Int, Int((0.82 * 255).rounded()))
            XCTAssertEqual(model.presentation.level, 0.82)
            XCTAssertEqual(model.brightness, 0)
            model.enabled = false; model.tick()
            XCTAssertEqual(model.output, 0)
        }
    }

    @MainActor func testOptionalCueAndUnavailableBatteryRemainCorrectWithZeroManualLevel() {
        fixture(manual: 0) { model, _ in
            model.batteryOptions.readyEnabled = true
            model.batteryOptions.readyThreshold = 0.8
            model.batteryOptions.readyStyle = .blink
            model.batteryOptions.readyDuration = 1
            model.updateBattery(.init(level: 0.79, externalPower: true, activelyCharging: false))
            _ = model.effectOutput(at: 0)
            model.updateBattery(.init(level: 0.8, externalPower: true, activelyCharging: false))
            XCTAssertEqual(model.effectOutput(at: 1), 1)
            XCTAssertEqual(model.effectOutput(at: 1.25), 0)
            XCTAssertEqual(model.effectOutput(at: 2), 1)
            model.updateBattery(nil)
            XCTAssertEqual(model.effectOutput(at: 3), 0)
        }
    }

    @MainActor func testOptionalPluggedInStylesKeepTheirOwnOutputAndSavedSettings() {
        for manual in savedLevels {
            for style in [BatteryChargeStyle.steady, .level] {
                fixture(manual: manual) { model, _ in
                    model.batteryOptions.chargingStyle = style
                    for percent in 0...100 {
                        model.updateBattery(.init(level: Double(percent)/100, externalPower: true, activelyCharging: true))
                        XCTAssertEqual(model.effectOutput(at: Double(percent)), style == .steady ? 1 : Double(percent)/100)
                        XCTAssertEqual(model.batteryOptions.chargingStyle, style)
                        XCTAssertEqual(model.brightness, manual)
                    }
                }
            }
        }
    }

    func testAllOtherModesStillHonorManualBrightness() {
        for mode in GlowMode.allCases where mode != .battery {
            for manual in savedLevels {
                var input = EffectInput()
                input.mode = mode; input.brightness = manual; input.audio = 1
                input.agent = .working; input.touchDown = true; input.signalLevel = 1
                for time in [0.0, 1, 3] { XCTAssertLessThanOrEqual(Effects.level(at: time, input: input), manual) }
            }
        }
    }
}
