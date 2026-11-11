import XCTest
@testable import Backlit

final class MusicCalibrationTests: XCTestCase {
    private func settled(energy: Double, automatic: Bool = true) -> Double {
        var response = MusicResponse(), output = 0.0
        for frame in 0..<400 {
            output = response.update(energy: energy, at: Double(frame) / 20,
                                     automatic: automatic, preset: .balanced)
        }
        return output
    }

    func testAutomaticPlaybackLeavesConsistentHeadroomAcrossVolumes() {
        for energy in [0.08, 0.2, 0.5, 0.8, 1] {
            XCTAssertEqual(settled(energy: energy), 0.6, accuracy: 0.000001)
        }
        XCTAssertGreaterThan(settled(energy: 0.03), settled(energy: 0.03, automatic: false) * 4)
        XCTAssertEqual(settled(energy: 0.008), 0)
    }

    func testManualPlaybackAndBrightnessCeilingStayUnchanged() {
        for energy in [0.03, 0.2, 0.6, 1] {
            XCTAssertEqual(settled(energy: energy, automatic: false), energy, accuracy: 0.000001)
            var input = EffectInput(); input.mode = .music
            input.audio = settled(energy: energy); input.brightness = 0.27
            for position in stride(from: 0.0, through: 1, by: 0.05) {
                input.intensity = MusicIntensity.multiplier(at: position)
                XCTAssertLessThanOrEqual(Effects.level(at: 20, input: input), 0.27)
            }
        }
    }

    func testIntensityMappingRoundTripsStoredMultipliersAndHasUsableMidpoint() {
        XCTAssertEqual(MusicIntensity.multiplier(at: 0), 0.25)
        XCTAssertEqual(MusicIntensity.multiplier(at: 1), 3)
        XCTAssertEqual(MusicIntensity.multiplier(at: 0.5), sqrt(0.75), accuracy: 0.000001)
        var previous = 0.0
        for value in stride(from: 0.25, through: 3, by: 0.01) {
            let position = MusicIntensity.position(for: value)
            XCTAssertGreaterThanOrEqual(position, previous)
            XCTAssertEqual(MusicIntensity.multiplier(at: position), value, accuracy: 0.000001)
            previous = position
        }
        for value in [Double.nan, .infinity, -.infinity, -1, 4] {
            XCTAssertTrue((0...1).contains(MusicIntensity.position(for: value)))
            XCTAssertTrue((0.25...3).contains(MusicIntensity.multiplier(at: value)))
        }
    }

    private func beatFixture(volume: Double = 1) -> [Double] {
        var response = MusicResponse(), tail: [Double] = []
        for frame in 0..<800 {
            let energy = (frame % 10 == 0 ? 0.5 : 0.2) * volume
            let level = response.update(energy: energy, at: Double(frame) / 20, automatic: true, preset: .balanced)
            if frame >= 400 { tail.append(level) }
        }
        return tail
    }

    func testMiddleSliderPreservesContrastInsteadOfFlatteningAtCeiling() throws {
        let levels = beatFixture()
        var previousMean = 0.0
        for position in [0.25, 0.5, 0.75] {
            let gain = MusicIntensity.multiplier(at: position)
            let values = levels.map { min(1, $0 * gain) }
            let mean = values.reduce(0, +) / Double(values.count)
            XCTAssertGreaterThan(mean, previousMean); previousMean = mean
            XCTAssertLessThan(try XCTUnwrap(values.max()), 1)
            if position == 0.5 {
                XCTAssertEqual(try XCTUnwrap(values.min()), 0.234, accuracy: 0.005)
                XCTAssertEqual(try XCTUnwrap(values.max()), 0.520, accuracy: 0.005)
            }
        }
    }

    func testAutomaticBeatContrastIsConsistentAcrossPlaybackVolumes() {
        let normal = beatFixture(), quieter = beatFixture(volume: 0.5)
        for (a, b) in zip(normal, quieter) { XCTAssertEqual(a, b, accuracy: 0.000001) }
    }

    func testDarkBetweenBeatsHasBothStatesAtMiddleIntensity() {
        let levels = beatFixture()
        var input = EffectInput(); input.mode = .music; input.brightness = 0.4
        input.intensity = MusicIntensity.multiplier(at: 0.5); input.strobe = true
        let output = levels.map { level -> Double in input.audio = level; return Effects.level(at: 20, input: input) }
        XCTAssertTrue(output.contains(0)); XCTAssertTrue(output.contains(0.4))
        XCTAssertTrue(output.allSatisfy { $0 == 0 || $0 == 0.4 })
    }

    @MainActor func testLoadingAndDisplayingIntensityDoesNotRewriteStoredGain() {
        let name = "local.backlit.test.music-intensity." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(1.37, forKey: "intensity")
        let model = AppModel(demo: true, defaults: defaults)
        defer { _ = model.prepareQuit(); defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(model.intensity, 1.37)
        XCTAssertEqual(model.musicIntensityPosition, MusicIntensity.position(for: 1.37))
        XCTAssertEqual(defaults.double(forKey: "intensity"), 1.37)
        model.musicIntensityPosition = 0.5
        XCTAssertEqual(defaults.double(forKey: "intensity"), sqrt(0.75), accuracy: 0.000001)
    }
}
