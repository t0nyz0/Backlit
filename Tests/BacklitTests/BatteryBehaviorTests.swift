import XCTest
import IOKit.ps
@testable import Backlit

final class BatteryBehaviorTests: XCTestCase {
    private func input(charge: Double = 0.75, pluggedIn: Bool = false, charging: Bool = false) -> EffectInput {
        var value = EffectInput()
        value.mode = .battery; value.brightness = 0.8; value.battery = charge
        value.externalPower = pluggedIn; value.activelyCharging = charging
        return value
    }

    func testActiveChargingPulsesWithinBrightnessCeiling() {
        let value = input(pluggedIn: true, charging: true)
        XCTAssertEqual(Effects.level(at: 0, input: value), 0.12, accuracy: 0.000001)
        XCTAssertEqual(Effects.level(at: 3, input: value), 0.8, accuracy: 0.000001)
        XCTAssertEqual(Effects.level(at: 6, input: value), 0.12, accuracy: 0.000001)
        for time in stride(from: 0.0, through: 60, by: 0.05) {
            XCTAssertTrue((0...0.8).contains(Effects.level(at: time, input: value)))
        }
    }

    func testFullAndPausedChargingRemainSolidAtEveryPhase() {
        for charge in [0.0, 0.5, 0.8, 0.99, 1.0] {
            let paused = input(charge: charge, pluggedIn: true)
            for time in [0.0, 1, 3, 5.9, 6, 120] {
                XCTAssertEqual(Effects.level(at: time, input: paused), 0.8)
            }
        }
        for active in [false, true] {
            let full = input(charge: 1, pluggedIn: true, charging: active)
            XCTAssertEqual(Effects.level(at: 0, input: full), 0.8)
            XCTAssertEqual(Effects.level(at: 4, input: full), 0.8)
        }
    }

    func testUnpluggedTracksEveryPercentageDownToExactlyZero() {
        for percent in 0...100 {
            // A stale charging flag must never make an unplugged battery pulse.
            let value = input(charge: Double(percent) / 100, charging: true)
            for time in [0.0, 3, 9] {
                XCTAssertEqual(Effects.level(at: time, input: value), 0.8 * Double(percent) / 100, accuracy: 0.000001)
            }
        }
    }

    func testUnplugReplugAndResumeChangeBehaviorImmediately() {
        var value = input(pluggedIn: true, charging: true)
        XCTAssertEqual(Effects.level(at: 0, input: value), 0.12, accuracy: 0.000001)
        value.externalPower = false
        XCTAssertEqual(Effects.level(at: 0, input: value), 0.6, accuracy: 0.000001)
        value.externalPower = true; value.activelyCharging = false
        XCTAssertEqual(Effects.level(at: 0, input: value), 0.8)
        value.activelyCharging = true
        XCTAssertEqual(Effects.level(at: 0, input: value), 0.12, accuracy: 0.000001)
    }

    func testOffUnavailableAndInvalidSamplesNeverPulse() {
        var value = input(pluggedIn: true, charging: true)
        value.enabled = false
        XCTAssertEqual(Effects.level(at: 3, input: value), 0)
        value.enabled = true; value.batteryAvailable = false
        XCTAssertEqual(Effects.level(at: 3, input: value), 0)
        value.batteryAvailable = true
        for charge in [Double.nan, .infinity, -.infinity] {
            value.battery = charge
            XCTAssertEqual(Effects.level(at: 3, input: value), 0)
        }
        value.battery = 0.8
        for time in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(Effects.level(at: time, input: value).isFinite)
        }
    }

    private func description() -> [String: Any] {
        [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true,
         kIOPSCurrentCapacityKey: 75.0, kIOPSMaxCapacityKey: 100.0,
         kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargingKey: true,
         kIOPSIsChargedKey: false]
    }

    func testPowerParserDistinguishesActivePausedFullAndUnplugged() throws {
        var data = description()
        let active = try XCTUnwrap(RuntimeServices.batterySnapshot(description: data))
        XCTAssertEqual(active.level, 0.75); XCTAssertTrue(active.externalPower); XCTAssertTrue(active.activelyCharging)
        data[kIOPSIsChargingKey] = false
        XCTAssertFalse(try XCTUnwrap(RuntimeServices.batterySnapshot(description: data)).activelyCharging)
        data[kIOPSIsChargingKey] = true; data[kIOPSIsChargedKey] = true
        XCTAssertFalse(try XCTUnwrap(RuntimeServices.batterySnapshot(description: data)).activelyCharging)
        data[kIOPSIsChargedKey] = false; data[kIOPSCurrentCapacityKey] = 100.0
        XCTAssertFalse(try XCTUnwrap(RuntimeServices.batterySnapshot(description: data)).activelyCharging)
        data[kIOPSCurrentCapacityKey] = 75.0; data[kIOPSPowerSourceStateKey] = kIOPSBatteryPowerValue
        let unplugged = try XCTUnwrap(RuntimeServices.batterySnapshot(description: data))
        XCTAssertFalse(unplugged.externalPower); XCTAssertFalse(unplugged.activelyCharging)
    }

    func testPowerParserRejectsUnavailableOrCorruptState() {
        for key in [kIOPSTypeKey, kIOPSCurrentCapacityKey, kIOPSMaxCapacityKey, kIOPSPowerSourceStateKey, kIOPSIsChargingKey] {
            var data = description(); data.removeValue(forKey: key)
            XCTAssertNil(RuntimeServices.batterySnapshot(description: data))
        }
        for pair: (String, Any) in [(kIOPSIsPresentKey, false), (kIOPSTypeKey, "UPS"),
                                   (kIOPSPowerSourceStateKey, "Unknown"), (kIOPSCurrentCapacityKey, Double.nan),
                                   (kIOPSCurrentCapacityKey, -1.0), (kIOPSMaxCapacityKey, 0.0),
                                   (kIOPSMaxCapacityKey, Double.infinity)] {
            var data = description(); data[pair.0] = pair.1
            XCTAssertNil(RuntimeServices.batterySnapshot(description: data))
        }
    }

    @MainActor func testFreshInstallDefaultsToAutomaticBatteryMode() {
        let suite = "local.backlit.test.battery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(model.mode, .battery)
        XCTAssertTrue(model.enabled)
        XCTAssertFalse(model.batteryIsPulsing)
    }

    @MainActor func testExistingPreferencesAndLegacyCustomizationArePreserved() {
        let suite = "local.backlit.test.battery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("battery", forKey: "mode"); defaults.set(0.45, forKey: "brightness")
        defaults.set(false, forKey: "enabled")
        let legacy = Data(#"{"chargingStyle":"level","readyEnabled":true,"readyStyle":"blink"}"#.utf8)
        defaults.set(legacy, forKey: "battery.response")
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(model.mode, .battery); XCTAssertEqual(model.brightness, 0.45); XCTAssertFalse(model.enabled)
        model.updateBattery(.init(level: 0.8, externalPower: true, activelyCharging: true))
        XCTAssertFalse(model.batteryIsPulsing); XCTAssertEqual(model.batteryPowerLabel, "Charging")
        XCTAssertEqual(model.batteryOptions.chargingStyle, .level)
        XCTAssertTrue(model.batteryOptions.readyEnabled)
        model.updateBattery(.init(level: 0.8, externalPower: true, activelyCharging: false))
        XCTAssertFalse(model.batteryIsPulsing); XCTAssertEqual(model.batteryPowerLabel, "Plugged in · Not charging")
        model.updateBattery(.init(level: 1, externalPower: true, activelyCharging: false))
        XCTAssertFalse(model.batteryIsPulsing); XCTAssertEqual(model.batteryPowerLabel, "Fully charged")
        model.updateBattery(.init(level: 0.5, externalPower: false, activelyCharging: false))
        XCTAssertFalse(model.batteryIsPulsing); XCTAssertEqual(model.batteryPowerLabel, "On battery")
        model.updateBattery(nil)
        XCTAssertFalse(model.batteryIsPulsing); XCTAssertFalse(model.batteryAvailable)
        XCTAssertEqual(model.batteryPowerLabel, "Battery state unavailable")
        XCTAssertEqual(defaults.data(forKey: "battery.response"), legacy)
        defaults.set("steady", forKey: "mode")
        XCTAssertEqual(AppModel(demo: true, defaults: defaults).mode, .steady, "An existing explicit mode choice is preserved")
    }
}
