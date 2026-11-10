import XCTest
@testable import Backlit

final class BatteryPulseMinimumTests: XCTestCase {
    func testDelayedFramesDeliverTheFloorAtCycleCrossingAndRestartSmoothly() {
        for cycle in [3.0, 6, 10] {
            for delay in [0.167, 0.25, 0.7, 4, 40] {
                for minimum in [0.0, 0.2, 0.9] {
                    var options = BatteryResponseOptions(); options.pulsePeriod = cycle; options.pulseMinimum = minimum
                    var response = BatteryResponse()
                    let started = 100.123
                    XCTAssertEqual(response.update(charge: 0.6, externalPower: true, at: started, options: options), minimum)
                    _ = response.update(charge: 0.6, externalPower: true, at: started + cycle - 0.1, options: options)
                    let crossed = started + cycle + delay
                    XCTAssertEqual(response.update(charge: 0.6, externalPower: true, at: crossed, options: options), minimum)
                    let next = response.update(charge: 0.6, externalPower: true, at: crossed + 0.05, options: options)
                    XCTAssertEqual(next, minimum, accuracy: 0.0000001)
                    XCTAssertEqual(response.update(charge: 0.6, externalPower: true, at: crossed + cycle/2, options: options), 1, accuracy: 0.000001)
                    XCTAssertEqual(response.update(charge: 0.37, externalPower: false, at: crossed + cycle, options: options), 0.37)
                    XCTAssertEqual(response.update(charge: 0.6, externalPower: true, at: crossed + cycle + 0.05, options: options, activelyCharging: false), 1)
                }
            }
        }
    }
    func testEverySamplePhaseReachesAnExplicitFloorAndHardwareDoesNotCoalesceOff() {
        for cycle in [3.0, 6, 10] {
            for offset in stride(from: 0.001, through: 0.049, by: 0.004) {
                var options = BatteryResponseOptions(); options.pulsePeriod = cycle
                var response = BatteryResponse(), floorFrames = 0
                for frame in 0...Int(cycle * 20) {
                    let output = response.update(charge: 0.6, externalPower: true, at: 100 + offset + Double(frame) / 20, options: options)
                    if output == 0 { floorFrames += 1 }
                }
                XCTAssertGreaterThanOrEqual(floorFrames, 2)
            }
        }
        for nearZero in [0.0001, 0.01, 0.1, 0.49] { XCTAssertTrue(LogoDevice.requiresWrite(from: nearZero, to: 0)) }
        XCTAssertFalse(LogoDevice.requiresWrite(from: 0, to: 0))
        XCTAssertFalse(LogoDevice.requiresWrite(from: 10, to: 10.49))
        XCTAssertTrue(LogoDevice.requiresWrite(from: 10, to: 10.5))
    }
    func testMinimumEndpointsTimingAndBoundsWithoutManualCeiling() {
        for minimum in [0.0, 0.01, 0.25, 0.5, 1] {
            var response = BatteryResponse(), options = BatteryResponseOptions()
            options.pulseMinimum = minimum
            XCTAssertEqual(response.update(charge: 0.75, externalPower: true, at: 0, options: options), minimum)
            XCTAssertEqual(response.update(charge: 0.75, externalPower: true, at: 3, options: options), 1)
            XCTAssertEqual(response.update(charge: 0.75, externalPower: true, at: 6, options: options), minimum, accuracy: 0.000001)
            XCTAssertEqual(response.requiresAnimation, minimum < 1)
            for step in 0..<120 {
                let level = response.update(charge: 0.75, externalPower: true, at: Double(step)/10, options: options)
                XCTAssertTrue(level.isFinite && (minimum...1).contains(level))
            }
        }
    }
    func testMinimumDoesNotAffectPausedFullUnpluggedOrOtherPluggedInStyles() {
        for minimum in [0.0, 0.9, 1] {
            var options = BatteryResponseOptions(); options.pulseMinimum = minimum
            var response = BatteryResponse()
            XCTAssertEqual(response.update(charge: 0.8, externalPower: true, at: 0, options: options, activelyCharging: false), 1)
            XCTAssertEqual(response.update(charge: 1, externalPower: true, at: 1, options: options), 1)
            XCTAssertEqual(response.update(charge: 0.37, externalPower: false, at: 2, options: options), 0.37)
            for style in [BatteryChargeStyle.steady, .level] {
                options.chargingStyle = style
                XCTAssertEqual(response.update(charge: 0.8, externalPower: true, at: 3, options: options), style == .steady ? 1 : 0.8)
            }
        }
    }
    func testStoredValuesMigrateClampAndResetToDarkDefault() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(BatteryResponseOptions.self, from: Data(#"{"pulsePeriod":4,"chargingStyle":"breathe"}"#.utf8)).pulseMinimum, 0)
        for (stored, expected) in [("-3", 0.0), ("5", 1.0), ("0.25", 0.25), ("null", 0), ("\"invalid\"", 0)] {
            let value = try decoder.decode(BatteryResponseOptions.self, from: Data("{\"pulseMinimum\":\(stored)}".utf8))
            XCTAssertEqual(value.pulseMinimum, expected)
        }
        var selected = BatteryResponseOptions(); selected.pulseMinimum = 0.42
        XCTAssertEqual(try decoder.decode(BatteryResponseOptions.self, from: JSONEncoder().encode(selected)).pulseMinimum, 0.42)
        selected = BatteryResponseOptions()
        XCTAssertEqual(selected.pulseMinimum, 0)
        XCTAssertEqual(selected.pulsePeriod, 6)
    }
    func testNonfiniteDirectOptionsAndExtremeClocksCannotPoisonOutput() {
        for minimum in [Double.nan, .infinity, -.infinity, -1, 100] {
            var options = BatteryResponseOptions(); options.pulseMinimum = minimum
            for cycle in [Double.nan, .infinity, 0, -1, Double.greatestFiniteMagnitude] {
                options.pulsePeriod = cycle
                var response = BatteryResponse()
                for time in [0.0, 1, 3, 6, Double.greatestFiniteMagnitude, Double.nan] {
                    let level = response.update(charge: 0.5, externalPower: true, at: time, options: options)
                    XCTAssertTrue(level.isFinite && (0...1).contains(level))
                }
            }
        }
    }
    @MainActor func testModelPreferencePersistenceAndDefaultRestoration() throws {
        let suite = "local.backlit.test.pulse-minimum." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.25, forKey: "brightness")
        let model = AppModel(demo: true, defaults: defaults)
        model.batteryOptions.pulseMinimum = 0.42
        let reloaded = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(reloaded.batteryOptions.pulseMinimum, 0.42)
        XCTAssertEqual(reloaded.brightness, 0.25)
        reloaded.batteryOptions = BatteryResponseOptions()
        XCTAssertEqual(try JSONDecoder().decode(BatteryResponseOptions.self, from: XCTUnwrap(defaults.data(forKey: "battery.response"))).pulseMinimum, 0)
        XCTAssertTrue(model.prepareQuit()); XCTAssertTrue(reloaded.prepareQuit())
    }
}
