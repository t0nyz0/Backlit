import XCTest
@testable import Backlit
final class EffectCadenceTests:XCTestCase {
    func effect(now:@escaping()->Double = {0}) -> ClosedLidEffect {
        .init(interface:.init(sample:{.init(factor:0.2,appliedNits:100,multiplier:1)},duration:{_ in true},logicalState:{_ in true},keepKeyboardDark:{true},now:now))
    }
    func testOnlySlowModesUseLowerFeedbackCadence() {
        for mode in [GlowMode.steady,.breathe,.battery] {XCTAssertEqual(EffectCadence.animationInterval(for:mode),0.1)}
        for mode in [GlowMode.music,.agents,.touch] {XCTAssertEqual(EffectCadence.animationInterval(for:mode),0.05)}
    }
    func testNativeInterpolationBudgetScalesWithSamplingInterval() throws {
        let fast=try effect().plan(0.7,frameInterval:0.05)
        let slow=try effect().plan(0.7,frameInterval:0.1)
        XCTAssertGreaterThan(try XCTUnwrap(slow.commands.last?.duration),try XCTUnwrap(fast.commands.last?.duration))
        for c in slow.commands {XCTAssertLessThanOrEqual(c.duration,5)}
    }
    func testCadenceSwitchDoesNotInvalidateTargetOrExtendDeadline() throws {
        var now=0.0
        let e=effect(now:{now})
        try e.execute(e.plan(0,frameInterval:0.1))
        now=1
        let wait=try e.plan(0,frameInterval:0.05)
        XCTAssertFalse(wait.hasWrites);try e.execute(wait)
        now=3
        XCTAssertThrowsError(try e.plan(0,frameInterval:0.1))
    }
    func testInvalidCadenceFailsBeforePlanning() {
        for interval in [0.0,-1,.nan,.infinity,1] {XCTAssertThrowsError(try effect().plan(0.5,frameInterval:interval))}
    }
}
