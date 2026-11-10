import XCTest
@testable import Backlit

final class BatteryMusicTests: XCTestCase {
    func testChargingBreatheSettlesAtFullWithoutAnAnimationTimer() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.chargingStyle = .breathe
        XCTAssertFalse(options.readyEnabled)
        XCTAssertLessThan(response.update(charge: 0.9, externalPower: true, at: 0, options: options), 1)
        XCTAssertTrue(response.requiresAnimation)
        XCTAssertEqual(response.update(charge: 1, externalPower: true, at: 1, options: options), 1)
        XCTAssertFalse(response.requiresAnimation)
        for (index, charge) in [0.99, 1, 0.98, 0.99].enumerated() {
            XCTAssertEqual(response.update(charge: charge, externalPower: true, at: Double(index + 2), options: options), 1)
            XCTAssertFalse(response.requiresAnimation, "Minor full-charge fluctuations must not restart breathing")
        }
        XCTAssertLessThan(response.update(charge: 0.97, externalPower: true, at: 6, options: options), 1)
        XCTAssertTrue(response.requiresAnimation)
    }

    func testFullChargingBreatheResetsOnUnplugAndTracksBatteryLevel() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.chargingStyle = .breathe
        XCTAssertEqual(response.update(charge: 1, externalPower: true, at: 0, options: options), 1)
        XCTAssertFalse(response.requiresAnimation, "Opening Battery while already full should stay solid")
        XCTAssertEqual(response.update(charge: 0.99, externalPower: false, at: 1, options: options), 0.99)
        XCTAssertFalse(response.requiresAnimation)
        XCTAssertLessThan(response.update(charge: 0.99, externalPower: true, at: 2, options: options), 1)
        XCTAssertTrue(response.requiresAnimation)
    }

    func testOptionalReadyCueFinishesWithSolidFullCharge() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.chargingStyle = .breathe
        options.readyEnabled = true; options.readyStyle = .pulse; options.readyDuration = 2
        _ = response.update(charge: 0.99, externalPower: true, at: 0, options: options)
        _ = response.update(charge: 1, externalPower: true, at: 1, options: options)
        XCTAssertTrue(response.completionActive)
        XCTAssertTrue(response.requiresAnimation)
        XCTAssertEqual(response.update(charge: 1, externalPower: true, at: 3, options: options), 1)
        XCTAssertFalse(response.completionActive)
        XCTAssertFalse(response.requiresAnimation)
    }

    func testBatteryPrimesFullWithoutClaimingACompletion() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.readyEnabled = true
        XCTAssertEqual(response.update(charge: 1, externalPower: true, at: 0, options: options), 1)
        XCTAssertTrue(response.ready)
        XCTAssertFalse(response.completionActive)
        XCTAssertFalse(response.requiresAnimation)
    }

    func testBatteryCompletionHasAHysteresisAndAFiniteDuration() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.readyEnabled = true; options.readyThreshold = 0.8
        options.readyDuration = 2; options.readyStyle = .blink
        _ = response.update(charge: 0.7, externalPower: true, at: 0, options: options)
        XCTAssertEqual(response.update(charge: 0.8, externalPower: true, at: 1, options: options), 1)
        XCTAssertTrue(response.completionActive)
        XCTAssertTrue(response.requiresAnimation)
        XCTAssertEqual(response.update(charge: 0.8, externalPower: true, at: 1.25, options: options), 0)
        _ = response.update(charge: 0.79, externalPower: true, at: 2, options: options)
        _ = response.update(charge: 0.8, externalPower: true, at: 3, options: options)
        XCTAssertFalse(response.completionActive, "Threshold jitter must not restart the cue")
        XCTAssertEqual(response.update(charge: 0.8, externalPower: true, at: 4, options: options), 0.8)
        _ = response.update(charge: 0.77, externalPower: true, at: 5, options: options)
        _ = response.update(charge: 0.8, externalPower: true, at: 6, options: options)
        XCTAssertTrue(response.completionActive)
    }

    func testUnplugCancelsCompletionAndReplugCanSignalReady() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.readyEnabled = true; options.readyStyle = .glow
        _ = response.update(charge: 0.9, externalPower: true, at: 0, options: options)
        _ = response.update(charge: 1, externalPower: true, at: 1, options: options)
        XCTAssertTrue(response.completionActive)
        XCTAssertFalse(response.requiresAnimation)
        XCTAssertEqual(response.update(charge: 1, externalPower: false, at: 2, options: options), 1)
        XCTAssertFalse(response.completionActive)
        XCTAssertFalse(response.ready)
        _ = response.update(charge: 1, externalPower: true, at: 3, options: options)
        XCTAssertTrue(response.completionActive)
    }

    func testEveryReadyPatternIsBoundedAndHasAMaximumDuration() {
        for style in BatteryReadyStyle.allCases {
            var response = BatteryResponse(), options = BatteryResponseOptions()
            options.readyEnabled = true; options.readyStyle = style
            options.readyDuration = Double.greatestFiniteMagnitude
            _ = response.update(charge: 0.9, externalPower: true, at: 0, options: options)
            for step in 0..<600 {
                let level = response.update(charge: 1, externalPower: true, at: 1 + Double(step) / 10, options: options)
                XCTAssertTrue(response.completionActive)
                XCTAssertEqual(response.requiresAnimation, style != .glow)
                XCTAssertTrue(level.isFinite); XCTAssertTrue((0...1).contains(level))
            }
            _ = response.update(charge: 1, externalPower: true, at: 61, options: options)
            XCTAssertFalse(response.completionActive)
        }
    }

    func testBatteryOptionsAndClockChangesDoNotManufactureAnEvent() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.readyEnabled = true
        _ = response.update(charge: 0.9, externalPower: true, at: 10, options: options)
        options.readyThreshold = 0.8
        _ = response.update(charge: 0.9, externalPower: true, at: 11, options: options)
        XCTAssertFalse(response.completionActive)
        _ = response.update(charge: 1, externalPower: true, at: 100, options: options)
        XCTAssertFalse(response.completionActive)
        _ = response.update(charge: 1, externalPower: true, at: 5, options: options)
        XCTAssertFalse(response.completionActive)
        response.reset()
        XCTAssertFalse(response.ready)
        XCTAssertFalse(response.requiresAnimation)
    }

    func testChargingStyleNeverChangesOnBatteryBehaviorOrBrightnessCeiling() {
        for style in BatteryChargeStyle.allCases {
            var response = BatteryResponse(), options = BatteryResponseOptions()
            options.chargingStyle = style
            XCTAssertEqual(response.update(charge: 0.4, externalPower: false, at: 0, options: options), 0.4)
            XCTAssertFalse(response.requiresAnimation)
            let multiplier = response.update(charge: 0.4, externalPower: true, at: 3, options: options)
            XCTAssertGreaterThanOrEqual(multiplier, 0)
            XCTAssertLessThanOrEqual(multiplier, 1)
            var input = EffectInput(); input.mode = .battery
            input.brightness = 0.27; input.battery = multiplier
            XCTAssertLessThanOrEqual(Effects.level(at: 3, input: input), 0.27)
            XCTAssertEqual(response.requiresAnimation, style == .breathe)
        }
    }

    func testBatteryRejectsInvalidSamplesAndBoundsInvalidOptions() {
        var response = BatteryResponse(), options = BatteryResponseOptions()
        options.readyEnabled = true; options.readyDuration = .infinity
        options.readyThreshold = .nan
        XCTAssertEqual(response.update(charge: .nan, externalPower: true, at: 0, options: options), 0)
        XCTAssertEqual(response.update(charge: 1, externalPower: true, at: .infinity, options: options), 0)
        for time in [0.0, 1, 30, Double.greatestFiniteMagnitude] {
            let level = response.update(charge: 1, externalPower: true, at: time, options: options)
            XCTAssertTrue(level.isFinite); XCTAssertTrue((0...1).contains(level))
        }
    }

    func testMusicAutomaticLevelHelpsQuietPlaybackWithoutExceedingCeiling() {
        var automatic = MusicResponse(), manual = MusicResponse()
        var autoLevel = 0.0, manualLevel = 0.0
        for frame in 0..<400 {
            let time = Double(frame) / 20
            autoLevel = automatic.update(energy: 0.03, at: time, automatic: true, preset: .balanced)
            manualLevel = manual.update(energy: 0.03, at: time, automatic: false, preset: .balanced)
        }
        XCTAssertGreaterThan(autoLevel, manualLevel * 4)
        XCTAssertLessThanOrEqual(automatic.adaptiveGain, 12.5)
        XCTAssertEqual(manual.adaptiveGain, 1)
        var input = EffectInput(); input.mode = .music
        input.brightness = 0.27; input.audio = autoLevel
        input.intensity = 0.5
        let quiet = Effects.level(at: 20, input: input)
        input.intensity = 1.5
        let louder = Effects.level(at: 20, input: input)
        XCTAssertGreaterThan(louder, quiet)
        XCTAssertLessThanOrEqual(louder, 0.27)
    }

    func testMusicDoesNotAmplifySilenceAndResetsStaleState() {
        var response = MusicResponse()
        for frame in 0..<200 {
            XCTAssertEqual(response.update(energy: 0.005, at: Double(frame) / 20,
                                           automatic: true, preset: .smooth), 0)
        }
        XCTAssertGreaterThan(response.update(energy: 1, at: 10, automatic: true, preset: .balanced), 0.8)
        XCTAssertEqual(response.update(energy: 0, at: 20, automatic: true, preset: .balanced), 0)
        XCTAssertEqual(response.update(energy: 0, at: 1, automatic: true, preset: .balanced), 0)
        XCTAssertEqual(response.update(energy: .nan, at: 2, automatic: true, preset: .balanced), 0)
        XCTAssertEqual(response.update(energy: 1, at: .infinity, automatic: true, preset: .balanced), 0)
    }

    func testMusicPresetsShapeTheSameSignalAndUseElapsedTime() {
        var smooth = MusicResponse(), punchy = MusicResponse()
        let slowRise = smooth.update(energy: 0.8, at: 0, automatic: false, preset: .smooth)
        let fastRise = punchy.update(energy: 0.8, at: 0, automatic: false, preset: .punchy)
        XCTAssertGreaterThan(fastRise, slowRise)
        let slowRelease = smooth.update(energy: 0, at: 0.1, automatic: false, preset: .smooth)
        let fastRelease = punchy.update(energy: 0, at: 0.1, automatic: false, preset: .punchy)
        XCTAssertGreaterThan(slowRelease, fastRelease)

        var fast = MusicResponse(), slow = MusicResponse()
        _ = fast.update(energy: 1, at: 0, automatic: false, preset: .balanced)
        _ = slow.update(energy: 1, at: 0, automatic: false, preset: .balanced)
        var a = 0.0, b = 0.0
        for frame in 1...20 { a = fast.update(energy: 0, at: Double(frame) / 100, automatic: false, preset: .balanced) }
        for frame in 1...4 { b = slow.update(energy: 0, at: Double(frame) / 20, automatic: false, preset: .balanced) }
        XCTAssertEqual(a, b, accuracy: 0.000_001)
        fast.reset()
        XCTAssertEqual(fast.update(energy: 0, at: 1, automatic: true, preset: .balanced), 0)
    }

    func testEveryMusicPresetIsFiniteAndBoundedAcrossInvalidRanges() {
        for preset in MusicResponsePreset.allCases {
            var response = MusicResponse()
            for (index, energy) in [-1.0, 0, 0.008, 0.1, 1, 4, Double.nan, Double.infinity].enumerated() {
                let level = response.update(energy: energy, at: Double(index) / 20, automatic: true, preset: preset)
                XCTAssertTrue(level.isFinite); XCTAssertTrue((0...1).contains(level))
            }
        }
    }
}
