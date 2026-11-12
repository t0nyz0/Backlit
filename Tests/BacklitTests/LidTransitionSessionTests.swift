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

    func testFailedRetirementDuringLidTransitionKeepsTheOldSession() {
        var made = 0
        let first = Session(failure: FadeSessionInterruption.sourceMode); first.restoreFails = true
        let owner = FadeSessionCoordinator(physicalLid: { false }, makeSession: { _ in made += 1; return first })
        for _ in 0..<3 { XCTAssertThrowsError(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1)) }
        XCTAssertTrue(owner.hasSession, "An unverified cleanup must never be replaced")
        XCTAssertEqual(made, 1)
    }

    func testInvalidClockDuringLidTransitionFailsClosed() {
        let first = Session(failure: FadeSessionInterruption.sourceMode)
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { .nan }, makeSession: { _ in first })
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1)) {
            XCTAssertFalse($0 is FadeSessionInterruption)
        }
    }
}
