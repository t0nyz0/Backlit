import XCTest
@testable import Backlit

/// Opening or closing the lid replaces the light session with one of the other
/// kind. That is expected behavior and must not spend the failure-retry budget.
final class LidTransitionSessionTests: XCTestCase {
    final class Session: FadeEffectSession {
        var needsAnimation = true
        var failure: Error?
        var restoreFails = false
        var restores = 0
        init(failure: Error? = nil) { self.failure = failure }
        func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult {
            if let failure { throw failure }; return .applied
        }
        func restore() throws {
            restores += 1
            if restoreFails { throw RuntimeServices.failure("unverified recovery") }
        }
    }

    private func context(closed: Bool, sleeping: Bool = false, locked: Bool = false) -> FadeSafetyContext {
        .init(lidClosed: closed, sleeping: sleeping, locked: locked, generation: 1)
    }

    func testPausePolicyIsDecidedBeforeSourceMismatch() {
        // A session created while asleep or locked has no independent source.
        // It must pause, not be reported as a failed session.
        for owns in [false, true] {
            XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: false, sleeping: true), ownsIndependentSource: owns, closedLidRequested: false), .paused)
            XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: false, locked: true), ownsIndependentSource: owns, closedLidRequested: true), .paused)
            XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: true), ownsIndependentSource: owns, closedLidRequested: false), .paused)
        }
    }

    func testSourceKindMustMatchLidPosition() {
        XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: false), ownsIndependentSource: true, closedLidRequested: false), .proceed)
        XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: true), ownsIndependentSource: false, closedLidRequested: true), .proceed)
        XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: true), ownsIndependentSource: true, closedLidRequested: true), .switchSource)
        XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: false), ownsIndependentSource: false, closedLidRequested: true), .switchSource)
        XCTAssertEqual(FadeRuntime.frameEntry(context: context(closed: false), ownsIndependentSource: false, closedLidRequested: false), .switchSource)
    }

    func testRepeatedLidTransitionsNeverExhaustTheRetryBudget() throws {
        var time = 0.0, made = 0
        var sessions: [Session] = []
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { time }, makeSession: { _ in
            made += 1
            let next = Session(); sessions.append(next); return next
        })
        for round in 0..<12 {
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
            let current = try XCTUnwrap(sessions.last)
            current.failure = FadeSessionInterruption.sourceMode
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting, "round \(round)")
            XCTAssertEqual(current.restores, 1, "The old session is retired with verified cleanup")
            XCTAssertFalse(owner.hasSession)
            XCTAssertFalse(owner.automaticRecoveryPending, "A lid transition is not a recovery")
            // No replacement before the short settle delay.
            time += 0.5
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
            XCTAssertEqual(made, round + 1)
            time += 0.5
        }
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
        XCTAssertEqual(made, 13)
    }

    func testLidTransitionsLeaveTheFullFailureBudgetAvailable() throws {
        var time = 0.0
        var current = Session()
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { time }, makeSession: { _ in current = Session(); return current })
        for _ in 0..<6 {
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
            current.failure = FadeSessionInterruption.sourceMode
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
            time += 1
        }
        // Three real lifecycle faults are still retried; the fourth is terminal.
        for delay in [1.0, 2.0, 4.0] {
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
            current.failure = FadeSessionInterruption.lifecycle
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
            time += delay
        }
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
        current.failure = FadeSessionInterruption.lifecycle
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1))
    }

    func testUnverifiedCleanupDuringLidTransitionIsRetriedThenReplaced() throws {
        var time = 0.0, made = 0
        let first = Session(failure: FadeSessionInterruption.sourceMode); first.restoreFails = true
        let next = Session()
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { time }, makeSession: { _ in made += 1; return made == 1 ? first : next })
        // The lid is still settling: cleanup cannot be verified yet.
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(first.restores, 1); XCTAssertTrue(owner.hasSession); XCTAssertTrue(owner.needsAnimation)
        // No hardware is touched again before the retry delay.
        time = 0.4
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(first.restores, 1)
        time = 0.5
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(first.restores, 2); XCTAssertEqual(made, 1, "Never replaced before verified cleanup")
        // Cleanup now verifies; the replacement starts after the settle delay.
        first.restoreFails = false
        time = 1.5
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(first.restores, 3); XCTAssertFalse(owner.hasSession); XCTAssertEqual(made, 1)
        time = 2.0
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(made, 1)
        time = 2.5
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
        XCTAssertEqual(made, 2); XCTAssertFalse(owner.automaticRecoveryPending)
    }

    func testCleanupThatNeverVerifiesStopsAfterABoundedNumberOfAttempts() throws {
        var time = 0.0, made = 0
        let first = Session(failure: FadeSessionInterruption.sourceMode); first.restoreFails = true
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { time }, makeSession: { _ in made += 1; return first })
        for attempt in 1..<FadeSessionCoordinator.swapRetirementLimit {
            XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting, "attempt \(attempt)")
            XCTAssertEqual(first.restores, attempt)
            time += 4
        }
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1)) {
            XCTAssertFalse($0 is FadeSessionInterruption, "The real cleanup error is reported")
        }
        XCTAssertEqual(first.restores, FadeSessionCoordinator.swapRetirementLimit)
        XCTAssertTrue(owner.hasSession, "An unverified cleanup must never be replaced")
        XCTAssertEqual(made, 1)
        // Explicit restoration is still the only way past a failed cleanup.
        first.restoreFails = false
        try owner.restore()
        XCTAssertFalse(owner.hasSession)
    }

    func testPendingLidCleanupIsNotBypassedByALidPause() throws {
        var time = 0.0, closed = false
        let first = Session(failure: FadeSessionInterruption.sourceMode); first.restoreFails = true
        let owner = FadeSessionCoordinator(physicalLid: { closed }, now: { time }, makeSession: { _ in first })
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        // Closed-lid lighting is withdrawn while cleanup is still pending.
        closed = true; time = 0.1
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        XCTAssertEqual(first.restores, 1, "Still inside the retry delay")
        first.restoreFails = false; time = 0.5
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        XCTAssertFalse(owner.hasSession)
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .paused)
    }

    func testInvalidClockDuringLidTransitionFailsClosed() {
        let first = Session(failure: FadeSessionInterruption.sourceMode)
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { .nan }, makeSession: { _ in first })
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1)) {
            XCTAssertFalse($0 is FadeSessionInterruption)
        }
    }
}
