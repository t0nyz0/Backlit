import XCTest
@testable import Backlit
final class ClosedLidEffectTests: XCTestCase {
    final class Fake {
        var sample: ClosedLidEffect.Sample? = .init(factor: 1, appliedNits: 1000, multiplier: 1)
        var events: [String] = []
        var keyboardOK = true
        var writesOK = true
        func make() -> ClosedLidEffect { .init(interface: .init(sample: { self.sample }, duration: { self.events.append("duration:\($0)"); return self.writesOK }, logicalState: { self.events.append("state:\($0)"); return self.writesOK }, keepKeyboardDark: { self.events.append("keyboard"); return self.keyboardOK })) }
    }
    func testFadeStartsWithKnownOppositeStateAndDarkKeyboard() throws {
        let f=Fake(), c=f.make(); try c.apply(0.3)
        XCTAssertEqual(Array(f.events.prefix(3)),["duration:1000000000.0","state:2","keyboard"]); XCTAssertEqual(Array(f.events.suffix(2)),["state:1","keyboard"])
    }
    func testRetargetUsesBoundedEasedStep() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);let n=f.events.count
        f.sample = .init(factor:0.8,appliedNits:1000,multiplier:1);try c.apply(0.4)
        XCTAssertEqual(f.events.count,n + 6)
    }
    func testArrivingAtInteriorTargetHoldsThenContinuesCleanly() throws {
        let f=Fake(),c=f.make();try c.apply(0.3)
        f.sample = .init(factor:0.305,appliedNits:1000,multiplier:1);try c.apply(0.3)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:1000000000.0","state:2","keyboard"])
        let n=f.events.count;try c.apply(0.3);XCTAssertEqual(n,f.events.count)
        try c.apply(0.7);XCTAssertEqual(Array(f.events.suffix(2)),["state:2","keyboard"])
    }
    func testOffDoesNotStopAboveZero() throws {
        let f=Fake(),c=f.make();try c.apply(0)
        f.sample = .init(factor:0.005,appliedNits:1000,multiplier:1);let n=f.events.count;try c.apply(0);XCTAssertGreaterThan(f.events.count,n)
        f.sample = .init(factor:0,appliedNits:1000,multiplier:1);try c.apply(0);XCTAssertGreaterThan(f.events.count,n)
    }
    func testNoTelemetryFailsBeforeWrite() {
        let f=Fake(),c=f.make();f.sample=nil;XCTAssertThrowsError(try c.apply(0.4));XCTAssertTrue(f.events.isEmpty)
    }
    func testMalformedTelemetryFailsBeforeWrite() {
        for sample in [ClosedLidEffect.Sample(factor:.nan,appliedNits:1000,multiplier:1), .init(factor:0.3,appliedNits:-1,multiplier:1), .init(factor:0.3,appliedNits:1000,multiplier:.infinity)] {
            let f=Fake(),c=f.make();f.sample=sample;XCTAssertThrowsError(try c.apply(0.4));XCTAssertTrue(f.events.isEmpty)
        }
    }
    func testKeyboardFailureRetainsRestoreOwnership() throws {
        let f=Fake(),c=f.make();f.keyboardOK=false;XCTAssertThrowsError(try c.apply(0.4));XCTAssertTrue(c.active)
        f.keyboardOK=true;try c.restore();XCTAssertFalse(c.active)
    }
    func testRestoreFailureRetainsOwnership() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);f.writesOK=false;XCTAssertThrowsError(try c.restore());XCTAssertTrue(c.active)
    }
    func testRestoreResetsFadeAndDoesNotRepeatWrites() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);try c.restore()
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:0.0","state:2","keyboard"])
        let n=f.events.count;try c.restore();XCTAssertEqual(n,f.events.count)
    }
    func testLowBaselineStillUsesFullRelativeEffectRange() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0.5,appliedNits:500,multiplier:1)
        try c.apply(0.5);XCTAssertTrue(f.events.isEmpty)
        try c.apply(0.8);XCTAssertTrue(c.needsAnimation)
    }
    func testStaticInteriorNeedsAnimationUntilSettled() throws {
        let f = Fake(), c = f.make(); try c.apply(0.3)
        XCTAssertTrue(c.needsAnimation)
        f.sample = .init(factor: 0.3, appliedNits: 1000, multiplier: 1)
        try c.apply(0.3); XCTAssertFalse(c.needsAnimation)
        c.relinquish(); XCTAssertFalse(c.active)
    }
    func testZeroBaselineWaitsAndRecoversWithoutDisablingControl() throws {
        let f=Fake(), c=f.make();f.sample = .init(factor:0,appliedNits:0,multiplier:1)
        try c.apply(0.8);XCTAssertTrue(f.events.isEmpty)
        f.sample = .init(factor:0,appliedNits:25,multiplier:1)
        try c.apply(0.8);XCTAssertTrue(c.needsAnimation)
    }
    func testWriteFailureStillAttemptsKeyboardSafety() {
        let f=Fake(), c=f.make();f.writesOK=false
        XCTAssertThrowsError(try c.apply(0.4))
        XCTAssertEqual(f.events.last,"keyboard")
    }
}
