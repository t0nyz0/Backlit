import XCTest
@testable import Backlit

final class AutomaticFadeRecoveryIntegrationTests: XCTestCase {
    final class Session: FadeEffectSession {
        let token = UUID()
        var recoveryToken: UUID? { token }
        var needsAnimation = false
        var failure: Error?
        var cleanup: () throws -> Void = {}
        var frames = 0
        func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult {
            frames += 1
            if let failure { throw failure }
            return .applied
        }
        func restore() throws { try cleanup() }
    }
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let boot = UUID()
        var now = 100.0
        var lidClosed = true
        var intent: LidSessionIntent? = .init(duration: .init())
        var receipt: UUID?
        var onVerify: (() -> Void)?
        lazy var store = AutomaticRecoveryStore(directory: directory)
        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func adapter() -> AutomaticFadeRecovery {
            .init(store: store, intent: { self.intent }, clock: { .init(boot: self.boot, seconds: self.now) },
                  verify: { token in self.onVerify?(); return self.receipt == token })
        }
        func coordinator(_ adapter: AutomaticFadeRecovery, sessions: [Session]) -> FadeSessionCoordinator {
            var remaining = sessions
            return .init(physicalLid: { self.lidClosed }, now: { self.now }, durableRecovery: adapter, makeSession: { _ in
                guard !remaining.isEmpty else { throw RuntimeServices.failure("Unexpected replacement") }
                return remaining.removeFirst()
            })
        }
    }
    private func fixture() throws -> Fixture {
        let f = try Fixture()
        addTeardownBlock { try FileManager.default.removeItem(at: f.directory) }
        return f
    }
    func testProductionRetirementProofRequiresExactReceiptAndNoNewJournal() throws {
        let f = try fixture()
        let fade = FadeRecoveryStore(directory: f.directory)
        let token = try fade.prepare(parentPID: 123, context: .init(lidClosed: true, sleeping: false, locked: false, generation: 1), keyboards: [7: 2])
        XCTAssertTrue(try fade.permitsRecovery(of: token))
        XCTAssertFalse(try fade.permitsRecovery(of: UUID()))
        XCTAssertFalse(try fade.verifiedRetirement(token: token))
        try fade.recover(token: token, restore: { _ in })
        XCTAssertTrue(try fade.verifiedRetirement(token: token))
        XCTAssertFalse(try fade.verifiedRetirement(token: UUID()))
        _ = try fade.prepare(parentPID: 124, context: .init(lidClosed: true, sleeping: false, locked: false, generation: 1), keyboards: [7: 2])
        XCTAssertFalse(try fade.verifiedRetirement(token: token), "Another owner's journal invalidates old retirement admission")
        XCTAssertFalse(try fade.permitsRecovery(of: token))
    }

    func testTypedInterruptionRecordsBeforeCleanupAndAutomaticallyConfirmsReplacement() throws {
        let f = try fixture(), first = Session(), second = Session()
        first.failure = FadeSessionInterruption.outputTimeout("inert transient")
        first.cleanup = {
            XCTAssertEqual(try f.store.snapshot()?.phase, .awaitingCleanup)
            XCTAssertEqual(try f.store.snapshot()?.sessionToken, first.token)
            f.receipt = first.token
        }
        let coordinator = f.coordinator(f.adapter(), sessions: [first, second])
        XCTAssertEqual(try coordinator.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
        XCTAssertEqual(second.frames, 0)
        f.now += 1
        XCTAssertEqual(try coordinator.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
        XCTAssertEqual(try f.store.snapshot()?.phase, .outputConfirmed)
        XCTAssertEqual(try f.store.snapshot()?.replacementToken, second.token)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
        XCTAssertFalse(coordinator.automaticRecoveryPending)
    }
    func testCleanupFailuresStayBoundedAcrossRelaunchAndNeverStartReplacement() throws {
        let f = try fixture(), first = Session(), second = Session()
        first.failure = FadeSessionInterruption.lifecycle
        var cleanupCalls = 0
        first.cleanup = { cleanupCalls += 1; throw RuntimeServices.failure("still restoring") }
        let owner = f.coordinator(f.adapter(), sessions: [first, second])
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        XCTAssertEqual(cleanupCalls, 1)
        // New process consumes another attempt before retrying the bound cleanup.
        let next = f.adapter()
        f.now += 1
        XCTAssertFalse(try next.prepareStartup(eligible: { true }, restore: { token in
            XCTAssertEqual(token, first.token); cleanupCalls += 1
            throw RuntimeServices.failure("still restoring")
        }))
        XCTAssertEqual(try f.store.snapshot()?.attempts, 2)
        f.now += 2
        XCTAssertThrowsError(try f.adapter().prepareStartup(eligible: { true }, restore: { _ in
            cleanupCalls += 1; throw RuntimeServices.failure("still restoring")
        }))
        XCTAssertEqual(try f.store.snapshot()?.attempts, 3)
        f.now += 4
        XCTAssertThrowsError(try f.adapter().prepareStartup(eligible: { true }, restore: { _ in XCTFail("Budget exhausted") }))
        XCTAssertEqual(cleanupCalls, 3); XCTAssertEqual(second.frames, 0)
    }
    func testReadyReceiptSurvivesRelaunchButConsumedClaimCannotReplay() throws {
        let f = try fixture(), token = UUID()
        let adapter = f.adapter()
        try adapter.begin(token: token, reason: .outputTimeout)
        f.receipt = token; try adapter.verified(token: token); f.now += 1
        let relaunched = f.adapter()
        XCTAssertTrue(try relaunched.prepareStartup(eligible: { true }, restore: { XCTAssertEqual($0, token) }))
        XCTAssertEqual(try f.store.snapshot()?.phase, .resumeClaimed)
        XCTAssertThrowsError(try f.adapter().prepareStartup(eligible: { true }, restore: { _ in XCTFail("Consumed claim") }))
        XCTAssertThrowsError(try f.adapter().admit())
    }
    func testOffDuringProofVetoesAdmissionAndUnrelatedFailureNeverEarnsRetry() throws {
        let f = try fixture(), first = Session()
        first.failure = RuntimeServices.failure("ownership changed")
        let owner = f.coordinator(f.adapter(), sessions: [first])
        XCTAssertThrowsError(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1))
        XCTAssertNil(try f.store.snapshot())
        let token = UUID(), adapter = f.adapter()
        try adapter.begin(token: token, reason: .lifecycle); f.receipt = token
        try adapter.verified(token: token); f.now += 1
        f.onVerify = { try! f.store.cancelPending() }
        XCTAssertThrowsError(try adapter.admit())
        XCTAssertEqual(try f.store.snapshot()?.phase, .cancelled)
    }
    func testRecoveredSessionCanSwitchToOpenLidWithoutReplayingOldReceipt() throws {
        let f = try fixture(), first = Session(), second = Session(), third = Session()
        first.failure = FadeSessionInterruption.lifecycle
        first.cleanup = { f.receipt = first.token }
        second.cleanup = { f.receipt = second.token }
        let owner = f.coordinator(f.adapter(), sessions: [first, second, third])
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .waiting)
        f.now += 1
        XCTAssertEqual(try owner.apply(1, closedLidRequested: true, frameInterval: 0.1), .applied)
        f.lidClosed = false; second.failure = FadeSessionInterruption.sourceMode
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .waiting)
        f.now += 1
        XCTAssertEqual(try owner.apply(1, closedLidRequested: false, frameInterval: 0.1), .applied)
        XCTAssertEqual(try f.store.snapshot()?.replacementToken, third.token)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
    }

    func testStartupCannotResumeWrongIntentExpiredSafetyOrUnprovenReceipt() throws {
        let f = try fixture(), token = UUID(), adapter = f.adapter()
        try adapter.begin(token: token, reason: .lifecycle)
        f.receipt = token; try adapter.verified(token: token); f.now += 1
        XCTAssertFalse(try f.adapter().prepareStartup(eligible: { false }, restore: { _ in XCTFail("Timer/safety denied") }))
        f.receipt = UUID()
        XCTAssertThrowsError(try f.adapter().prepareStartup(eligible: { true }, restore: { _ in }))
        f.intent = .init(duration: .init())
        XCTAssertThrowsError(try f.adapter().prepareStartup(eligible: { true }, restore: { _ in XCTFail("Wrong intent") }))
    }
}
