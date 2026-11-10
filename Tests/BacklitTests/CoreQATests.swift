import XCTest
@testable import Backlit

final class CoreQATests: XCTestCase {
    func testEffectClockCannotProduceNonfiniteOutput() {
        for mode in GlowMode.allCases {
            var input = EffectInput()
            input.mode = mode; input.brightness = 0.8; input.agent = .working
            input.audio = 0.8; input.touchDown = true
            for time in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(Effects.level(at: time, input: input), 0)
            }
            for time in [0, -1, Double.greatestFiniteMagnitude] {
                let level = Effects.level(at: time, input: input)
                XCTAssertTrue(level.isFinite && (0...(mode == .battery ? 1 : 0.8)).contains(level), "\(mode): \(level)")
            }
        }
    }

    func testInvalidBreathePeriodStillHasAFiniteBoundedCycle() {
        var input = EffectInput(); input.mode = .breathe; input.brightness = 0.7
        for period in [Double.nan, .infinity, -.infinity] {
            input.period = period
            XCTAssertGreaterThan(Effects.level(at: 3, input: input), 0.69)
            XCTAssertLessThan(Effects.level(at: 0, input: input), 0.03)
        }
    }
}
