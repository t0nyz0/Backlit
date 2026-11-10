import XCTest
@testable import Backlit
final class ClosedLidEffectTests: XCTestCase {
    final class Fake {
        var sample: ClosedLidEffect.Sample? = .init(factor: 1, appliedNits: 1000, multiplier: 1)
        var events: [String] = []
        var keyboardOK = true
        var writesOK = true
        var now = 0.0
        func make() -> ClosedLidEffect { .init(interface: .init(sample: { self.sample }, duration: { self.events.append("duration:\($0)"); return self.writesOK }, logicalState: { self.events.append("state:\($0)"); return self.writesOK }, keepKeyboardDark: { self.events.append("keyboard"); return self.keyboardOK }, now: { self.now })) }
    }
    func testFadeStartsWithKnownOppositeStateAndDarkKeyboard() throws {
        let f=Fake(), c=f.make(); try c.apply(0.3)
        XCTAssertEqual(Array(f.events.prefix(3)),["duration:5.0","state:2","keyboard"]); XCTAssertEqual(Array(f.events.suffix(2)),["state:1","keyboard"])
    }
    func testRetargetUsesBoundedEasedStep() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);let n=f.events.count
        f.sample = .init(factor:0.8,appliedNits:1000,multiplier:1);try c.apply(0.4)
        XCTAssertEqual(f.events.count,n + 6)
    }
    func testArrivingAtInteriorTargetHoldsThenContinuesCleanly() throws {
        let f=Fake(),c=f.make();try c.apply(0.3)
        f.sample = .init(factor:0.305,appliedNits:1000,multiplier:1);try c.apply(0.3)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:5.0","state:1","keyboard"])
        let n=f.events.count;try c.apply(0.3);XCTAssertEqual(n,f.events.count)
        try c.apply(0.7);XCTAssertEqual(Array(f.events.suffix(2)),["state:2","keyboard"])
    }
    func testOffDoesNotStopAboveZero() throws {
        let f=Fake(),c=f.make();try c.apply(0)
        f.sample = .init(factor:0.005,appliedNits:1000,multiplier:1);let n=f.events.count;try c.apply(0);XCTAssertGreaterThan(f.events.count,n)
        f.sample = .init(factor:0,appliedNits:1000,multiplier:1);try c.apply(0);XCTAssertGreaterThan(f.events.count,n)
    }
    func testInteriorHoldHasBoundedDarkTargetAndContinuesSampling() throws {
        let f=Fake(),c=f.make()
        f.sample = .init(factor:0.4,appliedNits:856,multiplier:1)
        try c.apply(0.4)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:5.0","state:1","keyboard"])
        XCTAssertTrue(c.needsAnimation)
        // Replaying actual drift causes a correction instead of accepting a
        // static hold forever. This verifies commands, not native ramp timing.
        f.sample = .init(factor:0.37,appliedNits:856,multiplier:1)
        let count=f.events.count;try c.apply(0.4)
        XCTAssertGreaterThan(f.events.count,count)
        for event in f.events where event.hasPrefix("duration:") {
            let duration=try XCTUnwrap(Double(event.dropFirst(9)))
            XCTAssertGreaterThanOrEqual(duration,0);XCTAssertLessThanOrEqual(duration,5)
        }
    }
    func testOffCancelsPendingRiseBeforeFirstHardwareFrame() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        try c.apply(0.7);try c.apply(0)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:0.0","state:1","keyboard"])
        XCTAssertFalse(c.needsAnimation)
    }
    func testOnCancelsPendingFallBeforeFirstHardwareFrame() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);try c.apply(1)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:0.0","state:2","keyboard"])
        XCTAssertFalse(c.needsAnimation)
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
        try c.apply(0.5);XCTAssertEqual(Array(f.events.suffix(3)),["duration:5.0","state:1","keyboard"]);XCTAssertTrue(c.needsAnimation)
        try c.apply(0.8);XCTAssertTrue(c.needsAnimation)
    }
    func testStaticInteriorNeedsAnimationUntilSettled() throws {
        let f = Fake(), c = f.make(); try c.apply(0.3)
        XCTAssertTrue(c.needsAnimation)
        f.sample = .init(factor: 0.3, appliedNits: 1000, multiplier: 1)
        try c.apply(0.3); XCTAssertTrue(c.needsAnimation)
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
    func testUnchangedTargetDoesNotStarveNativeFadeFromZero() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:1000,multiplier:1)
        try c.apply(0.96);let count=f.events.count
        for _ in 0..<10 {try c.apply(0.96)}
        XCTAssertEqual(f.events.count,count)
        XCTAssertTrue(c.needsAnimation)
    }
    func testInitialOffClaimsLogicalOffEvenWhenGateAlreadyDark() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:1000,multiplier:1)
        try c.apply(0)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:0.0","state:1","keyboard"])
        XCTAssertFalse(c.needsAnimation)
    }
    // These replay observed telemetry, not a substitute for physical lid QA.
    func testAcknowledgedWritesWithStuckZeroTelemetryNeverSettle() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        for _ in 0..<100 { try c.apply(0.96) }
        XCTAssertTrue(c.active)
        XCTAssertTrue(c.needsAnimation)
        XCTAssertEqual(f.events.filter { $0.hasPrefix("state:") }.count,2)
        XCTAssertEqual(f.sample?.factor,0)
    }
    func testDelayedHardwareRiseCanSettleAfterGateActuallyOpens() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        for _ in 0..<40 { try c.apply(0.7) }
        XCTAssertTrue(c.needsAnimation)
        f.sample = .init(factor:0.7,appliedNits:856,multiplier:1)
        try c.apply(0.7)
        XCTAssertTrue(c.needsAnimation)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:5.0","state:1","keyboard"])
    }
    func testRevocationWhileHardwareIsStuckDoesNotIssueLateRestoreWrites() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        try c.apply(0.7);let count=f.events.count
        c.relinquish();try c.restore()
        XCTAssertEqual(f.events.count,count)
        XCTAssertFalse(c.needsAnimation)
    }

    func testChangingTargetsDoNotRearmInitialZeroRiseGate() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        try c.apply(0.2);let count=f.events.count
        for i in 1...20 { f.now=Double(i)*0.05;try c.apply(Double(i)/25) }
        XCTAssertEqual(f.events.count,count)
        f.sample = .init(factor:0.1,appliedNits:856,multiplier:1)
        try c.apply(0.8);XCTAssertGreaterThan(f.events.count,count)
    }
    func testStuckGateTimesOutWithoutClaimingSuccessOrDroppingRecovery() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        try c.apply(0.7);let count=f.events.count;f.now=3
        XCTAssertThrowsError(try c.apply(0.8))
        XCTAssertEqual(f.events.count,count);XCTAssertTrue(c.active)
    }
    func testStaticInteriorRetargetsAfterActualMovement() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);let count=f.events.count
        f.sample = .init(factor:0.5,appliedNits:856,multiplier:1)
        try c.apply(0.3);XCTAssertGreaterThan(f.events.count,count)
    }

    func testSmallPositiveTargetDoesNotAcceptZeroAsSettled() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:856,multiplier:1)
        try c.apply(0.005)
        XCTAssertTrue(c.needsAnimation)
        XCTAssertEqual(Array(f.events.suffix(2)),["state:2","keyboard"])
    }

    func testPersistentlyUnavailableBaselineTimesOutWithoutWriting() {
        let f=Fake(),c=f.make();f.sample = .init(factor:0,appliedNits:0,multiplier:1)
        XCTAssertNoThrow(try c.apply(0.7));f.now=3
        XCTAssertThrowsError(try c.apply(0.7));XCTAssertTrue(f.events.isEmpty)
    }

}
