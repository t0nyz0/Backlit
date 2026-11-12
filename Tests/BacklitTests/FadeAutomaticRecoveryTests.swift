import XCTest
@testable import Backlit

final class FadeAutomaticRecoveryTests: XCTestCase {
    final class Session: FadeEffectSession {
        var needsAnimation = true
        var failure: Error? = FadeSessionInterruption.lifecycle
        var restoreFails = false
        var restores = 0
        func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult {
            if let failure { throw failure }; return .applied
        }
        func restore() throws {
            restores += 1
            if restoreFails { throw RuntimeServices.failure("unverified recovery") }
        }
    }
    func testHelperFirstLockThenWakeRetiresBeforeBackoffAndFreshSession() throws {
        var time = 0.0, made = 0
        let first = Session(), next = Session(); next.failure = nil
        let owner = FadeSessionCoordinator(physicalLid: {false}, now: {time}, makeSession: {_ in made += 1; return made == 1 ? first : next})
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        XCTAssertEqual(first.restores, 1); XCTAssertFalse(owner.hasSession); XCTAssertTrue(owner.automaticRecoveryPending)
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        XCTAssertEqual(made, 1)
        time = 1
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .applied)
        XCTAssertEqual(made, 2); XCTAssertFalse(owner.automaticRecoveryPending)
    }
    func testFailedRetirementNeverReplacesSession() {
        let first = Session(); first.restoreFails = true; var made = 0
        let owner = FadeSessionCoordinator(physicalLid: {false}, makeSession: {_ in made += 1; return first})
        for _ in 0..<3 { XCTAssertThrowsError(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1)) }
        XCTAssertTrue(owner.hasSession); XCTAssertEqual(made, 1)
    }
    func testRetryBudgetStopsRepeatedReplacement() throws {
        var time = 0.0, made = 0
        var current = Session()
        let owner = FadeSessionCoordinator(physicalLid: {false}, now: {time}, makeSession: {_ in made += 1; current = Session(); return current})
        for deadline in [0.0, 1.0, 3.0] {
            time = deadline
            XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        }
        time = 7
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1))
        XCTAssertEqual(made, 4); XCTAssertEqual(current.restores, 1)
        time = 100
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1))
        XCTAssertEqual(made, 4, "Exhaustion must remain latched until explicit restoration")
        var pendingChecks = 0
        XCTAssertThrowsError(try owner.restore(recoverPending: {
            pendingChecks += 1
            throw RuntimeServices.failure("Durable cleanup remains unverified")
        }))
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1))
        XCTAssertEqual(made, 4, "Failed durable cleanup cannot clear the exhausted latch")
        try owner.restore(recoverPending: { pendingChecks += 1 })
        XCTAssertEqual(pendingChecks, 2)
        XCTAssertFalse(owner.automaticRecoveryPending)
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        XCTAssertEqual(made, 5)
    }
    func testBriefSuccessDoesNotResetRetryBudget() throws {
        var time = 0.0
        var current = Session()
        let owner = FadeSessionCoordinator(physicalLid: {false}, now: {time}, makeSession: {_ in current = Session(); current.failure = nil; return current})
        for _ in 0..<3 {
            XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .applied)
            current.failure = FadeSessionInterruption.lifecycle
            XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
            time += 5
        }
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .applied)
        current.failure = FadeSessionInterruption.lifecycle
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1))
    }
    func testMatchingCompletionReceiptIsRequired() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FadeRecoveryStore(directory: dir)
        let token = try store.prepare(parentPID: 1, context: .init(lidClosed: false, sleeping: false, locked: false, generation: 1), keyboards: [13: 2])
        XCTAssertFalse(FadeRuntime.interrupted(record: try store.read(), completed: false, token: token, helperAlive: true))
        try store.acknowledgeWatchdog(token: token, watchdogPID: 2, parentAlive: {_ in true})
        let before = FadeSafetyContext(lidClosed: false, sleeping: false, locked: false, generation: 1)
        let after = FadeSafetyContext(lidClosed: false, sleeping: false, locked: false, generation: 2)
        let liveRecord = try store.read()
        XCTAssertTrue(liveRecord.effectsAllowed)
        XCTAssertTrue(FadeRuntime.safetyTransitionInterrupted(record: liveRecord, token: token, before: before, after: after), "A transition away and back can precede watchdog revocation")
        XCTAssertFalse(FadeRuntime.safetyTransitionInterrupted(record: liveRecord, token: token, before: before, after: before))
        XCTAssertFalse(FadeRuntime.safetyTransitionInterrupted(record: liveRecord, token: UUID(), before: before, after: after))
        XCTAssertFalse(FadeRuntime.safetyTransitionInterrupted(record: nil, token: token, before: before, after: after))
        XCTAssertFalse(FadeRuntime.safetyTransitionInterrupted(record: liveRecord, token: token, before: nil, after: after))
        XCTAssertFalse(FadeRuntime.safetyTransitionInterrupted(record: liveRecord, token: token, before: before, after: nil))
        XCTAssertTrue(FadeRuntime.interrupted(record: try store.read(), completed: false, token: token, helperAlive: false))
        XCTAssertFalse(FadeRuntime.interrupted(record: try store.read(), completed: true, token: UUID(), helperAlive: false))
        XCTAssertThrowsError(try store.recover(token: token) {_ in throw RuntimeServices.failure("transient restoration failure")})
        XCTAssertTrue(FadeRuntime.interrupted(record: try store.read(), completed: false, token: token, helperAlive: true), "Revocation can precede helper exit")
        try store.recover(token: token) {_ in}
        XCTAssertTrue(FadeRuntime.interrupted(record: nil, completed: store.completed(token: token), token: token, helperAlive: true))
        XCTAssertFalse(FadeRuntime.interrupted(record: nil, completed: store.completed(token: UUID()), token: token, helperAlive: false))
    }
    func testDelayedEndpointSuccessBeatsDeadlineButStuckEndpointIsRetryable() throws {
        var time = 0.0, factor = 0.5
        let effect = ClosedLidEffect(interface: .init(sample: {.init(factor: factor, appliedNits: 100, multiplier: 1)}, duration: {_ in true}, logicalState: {_ in true}, keepKeyboardDark: {true}, now: {time}))
        try effect.apply(1)
        time = 10; factor = 1
        XCTAssertNoThrow(try effect.apply(1)); XCTAssertFalse(effect.needsAnimation)
        factor = 0.5; try effect.apply(0)
        time = 14
        XCTAssertThrowsError(try effect.apply(0)) { XCTAssertTrue($0 is FadeSessionInterruption) }
        time = .nan
        XCTAssertThrowsError(try effect.apply(0)) { XCTAssertFalse($0 is FadeSessionInterruption) }
    }
    func testZeroRiseTimeoutAndInvalidClockAreDistinct() throws {
        var time = 0.0
        let effect = ClosedLidEffect(interface: .init(sample: {.init(factor: 0, appliedNits: 100, multiplier: 1)}, duration: {_ in true}, logicalState: {_ in true}, keepKeyboardDark: {true}, now: {time}))
        try effect.apply(0.5)
        time = 4
        XCTAssertThrowsError(try effect.apply(0.5)) { XCTAssertTrue($0 is FadeSessionInterruption) }
        time = .nan
        XCTAssertThrowsError(try effect.apply(0.5)) { XCTAssertFalse($0 is FadeSessionInterruption) }
    }
    func testZeroBaselineTimeoutRequiresValidClock() throws {
        var time = 0.0
        let effect = ClosedLidEffect(interface: .init(sample: {.init(factor: 0, appliedNits: 0, multiplier: 1)}, duration: {_ in true}, logicalState: {_ in true}, keepKeyboardDark: {true}, now: {time}))
        try effect.apply(0.5)
        time = 4
        XCTAssertThrowsError(try effect.apply(0.5)) { XCTAssertTrue($0 is FadeSessionInterruption) }
        time = -1
        XCTAssertThrowsError(try effect.apply(0.5)) { XCTAssertFalse($0 is FadeSessionInterruption) }
    }
}
