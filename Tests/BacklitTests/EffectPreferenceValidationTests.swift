import XCTest
@testable import Backlit

@MainActor final class EffectPreferenceValidationTests: XCTestCase {
    private func fixture(_ values: [String: Any],
                         _ check: (AppModel, UserDefaults) throws -> Void) rethrows {
        let suite = "local.backlit.test.effect-preferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("steady", forKey: "mode")
        defaults.set("fixture-installation", forKey: "installation.id")
        defaults.set(Data([0, 1, 2, 255]), forKey: "unrelated.fixture")
        for (key, value) in values { defaults.set(value, forKey: key) }
        let model = AppModel(demo: true, defaults: defaults)
        defer {
            XCTAssertTrue(model.prepareQuit())
            defaults.removePersistentDomain(forName: suite)
        }
        try check(model, defaults)
        XCTAssertEqual(defaults.data(forKey: "unrelated.fixture"), Data([0, 1, 2, 255]))
    }

    func testMissingValuesKeepExistingDefaultsWithoutCreatingPreferenceKeys() {
        fixture([:]) { model, defaults in
            XCTAssertEqual(model.brightness, 0.68)
            XCTAssertEqual(model.period, 6)
            XCTAssertEqual(model.intensity, 1)
            for key in ["brightness", "period", "intensity"] { XCTAssertNil(defaults.object(forKey: key)) }
        }
    }

    func testValidSavedValuesAndUnrelatedPreferencesArePreserved() {
        for (brightness, period, intensity) in [(0.0, 3.0, 0.25), (0.93, 3.2, 1.7), (1.0, 10.0, 3.0)] {
            fixture(["brightness": brightness, "period": period, "intensity": intensity]) { model, defaults in
                XCTAssertEqual(model.brightness, brightness)
                XCTAssertEqual(model.period, period)
                XCTAssertEqual(model.intensity, intensity)
                XCTAssertEqual(defaults.double(forKey: "brightness"), brightness)
                XCTAssertEqual(defaults.double(forKey: "period"), period)
                XCTAssertEqual(defaults.double(forKey: "intensity"), intensity)
            }
        }
    }

    func testLegitimateNumericStringsRemainAcceptedWithoutRewritingTheirTypes() {
        let values = ["brightness": " 0.42\n", "period": "4.25", "intensity": "1.8e0"]
        fixture(values) { model, defaults in
            XCTAssertEqual(model.brightness, 0.42)
            XCTAssertEqual(model.period, 4.25)
            XCTAssertEqual(model.intensity, 1.8)
            for (key, value) in values { XCTAssertEqual(defaults.string(forKey: key), value) }
        }
    }

    func testFiniteOutOfRangeValuesMatchExistingEngineBoundsWithoutRewritingStorage() {
        for (raw, brightness, period, intensity) in [(-100.0, 0.0, 3.0, 0.25), (100.0, 1.0, 10.0, 3.0)] {
            fixture(["brightness": raw, "period": raw, "intensity": raw]) { model, defaults in
                XCTAssertEqual(model.brightness, brightness)
                XCTAssertEqual(model.period, period)
                XCTAssertEqual(model.intensity, intensity)
                for key in ["brightness", "period", "intensity"] { XCTAssertEqual(defaults.double(forKey: key), raw) }
                XCTAssertTrue(model.effectOutput(at: 0).isFinite)
            }
        }
    }

    func testNonfiniteSavedValuesBecomeFiniteWithoutBrighteningOrRewritingStorage() {
        for raw in [Double.nan, .infinity, -.infinity] {
            fixture(["brightness": raw, "period": raw, "intensity": raw]) { model, defaults in
                XCTAssertEqual(model.brightness, 0)
                XCTAssertEqual(model.period, 6)
                XCTAssertEqual(model.intensity, 0.25)
                XCTAssertEqual(model.effectOutput(at: 0), 0)
                for key in ["brightness", "period", "intensity"] {
                    let stored = defaults.double(forKey: key)
                    if raw.isNaN { XCTAssertTrue(stored.isNaN) }
                    else { XCTAssertEqual(stored, raw) }
                }
            }
        }
    }

    func testMalformedBooleansCollectionsAndNonnumericStringsUseSafeFallbacks() throws {
        let malformed: [Any] = [true, false, "not-a-number", "", [0.6], ["value": 0.6], Data([1, 2])]
        for raw in malformed {
            let before = try PropertyListSerialization.data(fromPropertyList: ["raw": raw], format: .binary, options: 0)
            try fixture(["brightness": raw, "period": raw, "intensity": raw]) { model, defaults in
                XCTAssertEqual(model.brightness, 0, "raw=\(raw)")
                XCTAssertEqual(model.period, 6, "raw=\(raw)")
                XCTAssertEqual(model.intensity, 0.25, "raw=\(raw)")
                XCTAssertEqual(model.effectOutput(at: 0), 0)
                for key in ["brightness", "period", "intensity"] {
                    let after = try PropertyListSerialization.data(fromPropertyList: ["raw": defaults.object(forKey: key)!], format: .binary, options: 0)
                    XCTAssertEqual(after, before, "Initialization must not rewrite \(key)")
                }
            }
        }
    }

    func testConservativeIntensityFallbackDoesNotIncreaseActualEffectOutput() {
        // Compare the production effect engine, not just the slider conversion.
        for raw in [Double.nan, .infinity, -.infinity, -100, 0, 100] {
            let normalized = EffectPreferenceValues(brightness: 0.8, period: 6, intensity: raw)
            for energy in [0.0, 0.01, 0.1, 0.5, 1] {
                for strobe in [false, true] {
                    var original = EffectInput()
                    original.mode = .music; original.brightness = 0.8
                    original.audio = energy; original.intensity = raw; original.strobe = strobe
                    var repaired = original; repaired.intensity = normalized.intensity
                    let before = Effects.level(at: 0, input: original)
                    let after = Effects.level(at: 0, input: repaired)
                    XCTAssertTrue(after.isFinite)
                    XCTAssertLessThanOrEqual(after, before, "raw=\(raw), energy=\(energy), strobe=\(strobe)")
                }
            }
        }
    }

    func testMalformedIntensityFallbackDoesNotIncreasePriorUserDefaultsEffect() {
        let malformed: [Any] = [true, false, "not-a-number", [0.6], ["value": 0.6]]
        for raw in malformed {
            fixture(["intensity": raw]) { _, defaults in
                let normalized = EffectPreferenceValues(brightness: 0.8, period: 6, intensity: raw)
                for energy in [0.0, 0.1, 0.5, 1] {
                    var original = EffectInput()
                    original.mode = .music; original.brightness = 0.8
                    original.audio = energy; original.intensity = defaults.double(forKey: "intensity")
                    var repaired = original; repaired.intensity = normalized.intensity
                    XCTAssertLessThanOrEqual(Effects.level(at: 0, input: repaired), Effects.level(at: 0, input: original))
                }
            }
        }
    }
}
