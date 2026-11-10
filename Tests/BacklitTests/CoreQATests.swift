import XCTest
@testable import Backlit

final class CoreQATests: XCTestCase {
    func testRevokingExternalAutomationKeepsLocalFocusDeadlineAndProgress() throws {
        var engine = ActivitySignalEngine()
        engine.submit(try ActivitySignal(category: .focus, state: .active, duration: 120), at: 0, source: .local)
        engine.submit(try ActivitySignal(category: .recording, state: .active, duration: 90), at: 1)
        _ = engine.level(at: 5)
        XCTAssertEqual(engine.current?.category, .recording)
        engine.clearExternal()
        XCTAssertEqual(engine.level(at: 60), 0.59, accuracy: 0.0001)
        XCTAssertEqual(engine.current?.category, .focus)
        XCTAssertEqual(engine.count, 1)
        _ = engine.level(at: 120)
        XCTAssertEqual(engine.current?.state, .complete)
    }

    func testExternalFocusCannotOverwriteOrClearLocalFocus() throws {
        var engine = ActivitySignalEngine()
        engine.submit(try ActivitySignal(category: .focus, state: .active, duration: 100), at: 0, source: .local)
        engine.submit(try ActivitySignal(category: .focus, state: .active, duration: 20), at: 5)
        _ = engine.level(at: 10)
        XCTAssertEqual(engine.count, 2)
        engine.submit(try ActivitySignal(category: .focus, state: .clear), at: 10)
        XCTAssertEqual(engine.level(at: 50), 0.59, accuracy: 0.0001)
        XCTAssertEqual(engine.count, 1)
        _ = engine.level(at: 100)
        XCTAssertEqual(engine.current?.state, .complete)
        engine.reset()
        XCTAssertEqual(engine.level(at: 101), 0)
    }

    func testRevocationAlsoClearsExternalFocusCompletionCue() throws {
        var engine = ActivitySignalEngine()
        engine.submit(try ActivitySignal(category: .focus, state: .active, duration: 2), at: 0)
        _ = engine.level(at: 2)
        XCTAssertEqual(engine.current?.state, .complete)
        engine.clearExternal()
        XCTAssertEqual(engine.level(at: 3), 0)
    }

    func testEffectClockCannotProduceNonfiniteOutput() {
        for mode in GlowMode.allCases {
            var input = EffectInput()
            input.mode = mode; input.brightness = 0.8; input.agent = .working
            input.audio = 0.8; input.touchDown = true; input.signalLevel = 0.8
            for time in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(Effects.level(at: time, input: input), 0)
            }
            for time in [0, -1, Double.greatestFiniteMagnitude] {
                let level = Effects.level(at: time, input: input)
                XCTAssertTrue(level.isFinite && (0...0.8).contains(level), "\(mode): \(level)")
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
