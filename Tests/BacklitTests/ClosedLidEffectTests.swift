import XCTest
@testable import Backlit
final class ClosedLidEffectTests: XCTestCase {
    final class Fake {
        var sample: ClosedLidEffect.Sample? = .init(factor: 1, appliedNits: 1000, multiplier: 1)
        var events: [String] = []
        var keyboardOK = true
        var writesOK = true
        var failedEvent: String?
        var onDuration: ((Double) -> Void)?
        var onState: ((Int) -> Void)?
        var now = 0.0
        func write(_ event: String) -> Bool { events.append(event); return writesOK && failedEvent != event }
        func make() -> ClosedLidEffect { .init(interface: .init(sample: { self.sample }, duration: {
            guard self.write("duration:\($0)") else { return false }; self.onDuration?($0); return true
        }, logicalState: {
            guard self.write("state:\($0)") else { return false }; self.onState?($0); return true
        }, keepKeyboardDark: { self.events.append("keyboard"); return self.keyboardOK }, now: { self.now })) }
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
    func testOffWaitsForExactZeroWithoutRetargeting() throws {
        let f=Fake(),c=f.make();try c.apply(0)
        f.sample = .init(factor:0.005,appliedNits:1000,multiplier:1);let n=f.events.count;try c.apply(0)
        XCTAssertEqual(f.events.count,n);XCTAssertTrue(c.needsAnimation)
        f.sample = .init(factor:0,appliedNits:1000,multiplier:1);try c.apply(0)
        XCTAssertEqual(f.events.count,n);XCTAssertFalse(c.needsAnimation)
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
        XCTAssertTrue(c.needsAnimation)
        let count=f.events.count;try c.apply(0);XCTAssertEqual(f.events.count,count)
        XCTAssertFalse(c.needsAnimation)
    }
    func testOnCancelsPendingFallBeforeFirstHardwareFrame() throws {
        let f=Fake(),c=f.make();try c.apply(0.3);try c.apply(1)
        XCTAssertEqual(Array(f.events.suffix(3)),["duration:0.0","state:2","keyboard"])
        XCTAssertTrue(c.needsAnimation)
        let count=f.events.count;try c.apply(1);XCTAssertEqual(f.events.count,count)
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
        XCTAssertTrue(c.needsAnimation)
        let count=f.events.count;try c.apply(0);XCTAssertEqual(f.events.count,count)
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

    func testNearZeroAndNearOneUseOneExplicitEndpointRequest() throws {
        for (factor,target,state) in [(0.0000009,0.0,1),(0.9999991,1.0,2)] {
            let f=Fake(),c=f.make();f.sample = .init(factor:factor,appliedNits:856,multiplier:1)
            try c.apply(target)
            XCTAssertEqual(f.events,["duration:5.0","state:\(state == 1 ? 2 : 1)","keyboard","duration:0.0","state:\(state)","keyboard"])
            let count=f.events.count
            for tick in 1...20 {f.now=Double(tick)*0.05;try c.apply(target)}
            XCTAssertEqual(f.events.count,count);XCTAssertTrue(c.needsAnimation)
            f.sample = .init(factor:target,appliedNits:856,multiplier:1);try c.apply(target)
            XCTAssertEqual(f.events.count,count);XCTAssertFalse(c.needsAnimation)
            try c.apply(target);XCTAssertEqual(f.events.count,count)
        }
    }

    func testSameNativeStateIsPrimedBeforeZeroDurationEndpoint() throws {
        for target in [0.0,1.0] {
            let f=Fake(),c=f.make()
            var nativeState=target == 0 ? 1 : 2
            var duration=5.0
            f.sample = .init(factor:target == 0 ? 0.0000009 : 0.9999991,appliedNits:856,multiplier:1)
            f.onDuration = {duration=$0}
            f.onState = {state in
                // Faithful to the observed same-state no-op, not a hardware
                // timing claim: only a logical transition consumes duration.
                guard state != nativeState else {return}
                nativeState=state
                if duration == 0 {f.sample = .init(factor:state == 1 ? 0 : 1,appliedNits:856,multiplier:1)}
            }
            try c.apply(target);XCTAssertEqual(f.sample?.factor,target)
            XCTAssertTrue(c.needsAnimation)
            try c.apply(target);XCTAssertFalse(c.needsAnimation)
            XCTAssertEqual(f.events.filter{$0.hasPrefix("state:")}.count,2)
        }
    }

    func testKnownSameDirectionPrimesButOppositeDirectionDoesNot() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0.8,appliedNits:856,multiplier:1)
        try c.apply(0.3) // Known downward direction.
        let count=f.events.count;try c.apply(0)
        XCTAssertEqual(Array(f.events.dropFirst(count)),["duration:5.0","state:2","keyboard","duration:0.0","state:1","keyboard"])
        let next=f.events.count;try c.apply(1)
        XCTAssertEqual(Array(f.events.dropFirst(next)),["duration:0.0","state:2","keyboard"])
    }

    func testEndpointReversalWhileWaitingStartsNewBoundedRequest() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0.5,appliedNits:856,multiplier:1)
        try c.apply(0);let count=f.events.count
        f.now=2.9;try c.apply(1)
        XCTAssertEqual(Array(f.events.dropFirst(count)),["duration:0.0","state:2","keyboard"])
        let reversed=f.events.count;f.now=3.1;try c.apply(1)
        XCTAssertEqual(f.events.count,reversed);XCTAssertTrue(c.needsAnimation)
        f.sample = .init(factor:1,appliedNits:856,multiplier:1);try c.apply(1)
        XCTAssertFalse(c.needsAnimation)
    }

    func testInteriorTargetCancelsPendingEndpointAndUsesNormalFeedback() throws {
        let f=Fake(),c=f.make();f.sample = .init(factor:0.6,appliedNits:856,multiplier:1)
        try c.apply(0);let count=f.events.count
        f.now=2.9;try c.apply(0.4)
        XCTAssertGreaterThan(f.events.count,count)
        f.now=3.1;try c.apply(0.4);XCTAssertTrue(c.needsAnimation)
    }

    func testEndpointPrimeAndFinalFailuresRetainOwnershipAndKeyboardSafety() throws {
        for event in ["duration:5.0","state:2","duration:0.0","state:1"] {
            let f=Fake(),c=f.make();f.failedEvent=event
            XCTAssertThrowsError(try c.apply(0))
            XCTAssertTrue(c.active);XCTAssertEqual(f.events.last,"keyboard")
            if event == "duration:5.0" || event == "state:2" {
                XCTAssertFalse(f.events.contains("duration:0.0"),"Do not continue after a failed prime")
            }
            f.failedEvent=nil;try c.restore();XCTAssertFalse(c.active)
        }
    }

    func testEndpointTimeoutDoesNotReprimeOrReleaseRecovery() throws {
        for target in [0.0,1.0] {
            let f=Fake(),c=f.make();f.sample = .init(factor:0.5,appliedNits:856,multiplier:1)
            try c.apply(target);let count=f.events.count
            f.now=2.99;try c.apply(target);f.now=3
            XCTAssertThrowsError(try c.apply(target))
            XCTAssertEqual(f.events.count,count);XCTAssertTrue(c.active);XCTAssertTrue(c.needsAnimation)
        }
    }

    func testLostBaselineDoesNotExtendPendingEndpointDeadline() throws {
        let f=Fake(),c=f.make();try c.apply(0);let count=f.events.count
        f.now=2.5;f.sample = .init(factor:0.0000009,appliedNits:0,multiplier:1)
        try c.apply(0);XCTAssertTrue(c.needsAnimation)
        f.now=3;XCTAssertThrowsError(try c.apply(0));XCTAssertEqual(f.events.count,count)
    }

    func testRelinquishAndRestoreClearPendingEndpointState() throws {
        let f=Fake(),c=f.make();try c.apply(0);c.relinquish()
        f.now=10;try c.apply(1);try c.restore()
        f.now=20;try c.apply(0)
        XCTAssertTrue(c.active);XCTAssertTrue(c.needsAnimation)
    }

}
