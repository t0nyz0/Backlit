import XCTest
@testable import Backlit

final class AutomaticRecoveryStoreTests: XCTestCase {
    private func fixture() throws -> (URL, AutomaticRecoveryStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return (directory, AutomaticRecoveryStore(directory: directory))
    }
    func testVerifiedAdmissionIsTokenBoundDurableAndOneShot() throws {
        let (directory, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
        let clock = LidContinuousClock(boot: boot, seconds: 100)
        let record = try store.beginAttempt(intentID: intent, sessionToken: token, reason: .outputTimeout, clock: clock)
        XCTAssertEqual(record.phase, .awaitingCleanup)
        XCTAssertEqual(try store.snapshot(), record)
        XCTAssertFalse(try store.readiness(intentID: intent, clock: clock))
        XCTAssertThrowsError(try store.markVerified(intentID: intent, sessionToken: UUID(), verifyCompletion: { _ in XCTFail(); return true }))
        XCTAssertThrowsError(try store.markVerified(intentID: intent, sessionToken: token, verifyCompletion: { _ in false }))
        try store.markVerified(intentID: intent, sessionToken: token) { XCTAssertEqual($0, token); return true }
        let reopened = AutomaticRecoveryStore(directory: directory)
        XCTAssertFalse(try reopened.readiness(intentID: intent, clock: clock))
        let later = LidContinuousClock(boot: boot, seconds: 101)
        XCTAssertTrue(try reopened.readiness(intentID: intent, clock: later))
        XCTAssertThrowsError(try reopened.claimResume(intentID: intent, sessionToken: token, clock: later, verifyCompletion: { _ in false }))
        try reopened.claimResume(intentID: intent, sessionToken: token, clock: later) { $0 == token }
        XCTAssertFalse(try store.readiness(intentID: intent, clock: later))
        XCTAssertThrowsError(try store.claimResume(intentID: intent, sessionToken: token, clock: later, verifyCompletion: { _ in true }))
    }
    func testThreeAttemptsSharedAcrossRelaunchAndNoImplicitReset() throws {
        let (directory, _) = try fixture(), intent = UUID(), boot = UUID()
        for attempt in 1...3 {
            let store = AutomaticRecoveryStore(directory: directory), token = UUID()
            let start = Double(attempt * 10)
            let record = try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: start))
            XCTAssertEqual(record.attempts, attempt)
            XCTAssertEqual(record.retryAfter, start + pow(2, Double(attempt - 1)))
            XCTAssertThrowsError(try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: start)))
            try store.markVerified(intentID: intent, sessionToken: token) { _ in true }
            try store.claimResume(intentID: intent, sessionToken: token, clock: .init(boot: boot, seconds: record.retryAfter)) { _ in true }
        }
        let reopened = AutomaticRecoveryStore(directory: directory)
        XCTAssertThrowsError(try reopened.beginAttempt(intentID: intent, sessionToken: UUID(), reason: .lifecycle, clock: .init(boot: boot, seconds: 10_000)))
        XCTAssertEqual(try reopened.snapshot()?.attempts, 3)
        try reopened.clearAfterExplicitRecovery(intentID: intent)
        XCTAssertNil(try reopened.snapshot())
        XCTAssertEqual(try reopened.beginAttempt(intentID: intent, sessionToken: UUID(), reason: .lifecycle, clock: .init(boot: boot, seconds: 10_000)).attempts, 1)
    }
    func testUnfinishedCleanupConsumesBoundedAttemptsAcrossRelaunch() throws {
        let (directory, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
        var record = try store.beginAttempt(intentID: intent, sessionToken: token, reason: .outputTimeout, clock: .init(boot: boot, seconds: 1))
        XCTAssertFalse(try store.cleanupReadiness(intentID: intent, clock: .init(boot: boot, seconds: 1)))
        for attempt in 2...3 {
            let reopened = AutomaticRecoveryStore(directory: directory)
            XCTAssertTrue(try reopened.cleanupReadiness(intentID: intent, clock: .init(boot: boot, seconds: record.retryAfter)))
            record = try reopened.beginAttempt(intentID: intent, sessionToken: token, reason: .outputTimeout, clock: .init(boot: boot, seconds: record.retryAfter))
            XCTAssertEqual(record.attempts, attempt)
        }
        XCTAssertThrowsError(try AutomaticRecoveryStore(directory: directory).beginAttempt(intentID: intent, sessionToken: token, reason: .outputTimeout, clock: .init(boot: boot, seconds: record.retryAfter)))
        XCTAssertEqual(try store.snapshot()?.attempts, 3)
    }

    func testPendingAttemptCannotBeOverwrittenByNewSessionOrIntent() throws {
        let (_, store) = try fixture(), intent = UUID(), token = UUID(), clock = LidContinuousClock(boot: UUID(), seconds: 1)
        let initial = try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: clock)
        XCTAssertThrowsError(try store.beginAttempt(intentID: intent, sessionToken: UUID(), reason: .lifecycle, clock: clock))
        XCTAssertThrowsError(try store.beginAttempt(intentID: UUID(), sessionToken: token, reason: .lifecycle, clock: clock))
        XCTAssertThrowsError(try store.markVerified(intentID: UUID(), sessionToken: token, verifyCompletion: { _ in true }))
        XCTAssertThrowsError(try store.clearAfterExplicitRecovery(intentID: UUID()))
        XCTAssertEqual(try store.snapshot(), initial)
    }
    func testClockCorruptionRebootAndBackwardsTimeFailClosed() throws {
        let (_, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
        try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: 10))
        try store.markVerified(intentID: intent, sessionToken: token) { _ in true }
        for clock in [LidContinuousClock(boot: UUID(), seconds: 11), .init(boot: boot, seconds: 9), .init(boot: boot, seconds: .nan), .init(boot: boot, seconds: .infinity)] {
            XCTAssertThrowsError(try store.readiness(intentID: intent, clock: clock))
            XCTAssertThrowsError(try store.claimResume(intentID: intent, sessionToken: token, clock: clock, verifyCompletion: { _ in true }))
        }
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
        object["retryAfter"] = 50
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)
        XCTAssertThrowsError(try store.snapshot())
        XCTAssertThrowsError(try store.beginAttempt(intentID: intent, sessionToken: UUID(), reason: .lifecycle, clock: .init(boot: boot, seconds: 50)))
    }
    func testMalformedDataIsNotAbsenceAndExplicitRecoveryCanRemoveIt() throws {
        let (_, store) = try fixture()
        try Data("not-json".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.snapshot())
        XCTAssertThrowsError(try store.beginAttempt(intentID: UUID(), sessionToken: UUID(), reason: .lifecycle, clock: .init(boot: UUID(), seconds: 1)))
        try store.clearAfterExplicitRecovery()
        XCTAssertNil(try store.snapshot())
        try store.clearAfterExplicitRecovery()
    }
    func testVerificationCannotResurrectWithdrawnRecord() throws {
        for claim in [false, true] {
            let (_, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
            try store.beginAttempt(intentID: intent, sessionToken: token, reason: .outputTimeout, clock: .init(boot: boot, seconds: 1))
            if claim {
                try store.markVerified(intentID: intent, sessionToken: token) { _ in true }
                XCTAssertThrowsError(try store.claimResume(intentID: intent, sessionToken: token, clock: .init(boot: boot, seconds: 2)) { _ in
                    try store.clearAfterExplicitRecovery(intentID: intent); return true
                })
            } else {
                XCTAssertThrowsError(try store.markVerified(intentID: intent, sessionToken: token) { _ in
                    try store.clearAfterExplicitRecovery(intentID: intent); return true
                })
            }
            XCTAssertNil(try store.snapshot())
        }
    }
    func testCancellationRetainsProofAndBudgetAndSurvivesRelaunch() throws {
        for ready in [false, true] {
            let (directory, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
            let record = try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: 1))
            if ready { try store.markVerified(intentID: intent, sessionToken: token) { _ in true } }
            try store.cancelPending(intentID: intent)
            let reopened = AutomaticRecoveryStore(directory: directory)
            let saved = try XCTUnwrap(reopened.snapshot())
            XCTAssertEqual(saved.phase, .cancelled)
            XCTAssertEqual(saved.attempts, record.attempts)
            XCTAssertEqual(saved.sessionToken, token); XCTAssertEqual(saved.intentID, intent)
            XCTAssertFalse(try reopened.readiness(intentID: intent, clock: .init(boot: boot, seconds: 10)))
            XCTAssertFalse(try reopened.cleanupReadiness(intentID: intent, clock: .init(boot: boot, seconds: 10)))
            XCTAssertThrowsError(try reopened.claimResume(intentID: intent, sessionToken: token, clock: .init(boot: boot, seconds: 10), verifyCompletion: { _ in true }))
            XCTAssertThrowsError(try reopened.beginAttempt(intentID: intent, sessionToken: UUID(), reason: .lifecycle, clock: .init(boot: boot, seconds: 10)))
            XCTAssertThrowsError(try reopened.markVerified(intentID: intent, sessionToken: token, verifyCompletion: { _ in true }))
        }
    }

    func testCancellationDuringProofCallbackCannotBeOverwritten() throws {
        let (_, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
        try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: 1))
        XCTAssertThrowsError(try store.markVerified(intentID: intent, sessionToken: token) { _ in
            try store.cancelPending(intentID: intent); return true
        })
        XCTAssertEqual(try store.snapshot()?.phase, .cancelled)
    }

    private func confirmedFixture() throws -> (URL, AutomaticRecoveryStore, UUID, UUID, UUID, UUID) {
        let (directory, store) = try fixture(), intent = UUID(), retired = UUID(), replacement = UUID(), boot = UUID()
        try store.beginAttempt(intentID: intent, sessionToken: retired, reason: .outputTimeout, clock: .init(boot: boot, seconds: 1))
        try store.markVerified(intentID: intent, sessionToken: retired) { _ in true }
        try store.claimResume(intentID: intent, sessionToken: retired, clock: .init(boot: boot, seconds: 2)) { _ in true }
        try store.markOutputConfirmed(intentID: intent, priorSessionToken: retired, replacementToken: replacement)
        return (directory, store, intent, retired, replacement, boot)
    }
    func testOutputConfirmationBindsExactReplacementWithoutBudgetReset() throws {
        let (directory, store, intent, retired, replacement, boot) = try confirmedFixture()
        let original = try XCTUnwrap(store.snapshot())
        XCTAssertEqual(original.phase, .outputConfirmed)
        XCTAssertEqual(original.replacementToken, replacement)
        XCTAssertEqual(original.attempts, 1)
        XCTAssertEqual(try store.markOutputConfirmed(intentID: intent, priorSessionToken: retired, replacementToken: replacement), original)
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: intent, priorSessionToken: retired, replacementToken: UUID()))
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: UUID(), priorSessionToken: retired, replacementToken: replacement))
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: intent, priorSessionToken: UUID(), replacementToken: replacement))
        let reopened = AutomaticRecoveryStore(directory: directory)
        XCTAssertThrowsError(try reopened.beginAttempt(intentID: intent, sessionToken: UUID(), reason: .lifecycle, clock: .init(boot: boot, seconds: 10)))
        let next = try reopened.beginAttempt(intentID: intent, sessionToken: replacement, reason: .lifecycle, clock: .init(boot: boot, seconds: 10))
        XCTAssertEqual(next.attempts, 2)
        XCTAssertEqual(next.phase, .awaitingCleanup); XCTAssertNil(next.replacementToken)
    }
    func testContinuationConsumesExactReplacementHandbackBeforeNewOutput() throws {
        let (directory, store, intent, retired, replacement, boot) = try confirmedFixture()
        let reopened = AutomaticRecoveryStore(directory: directory), clock = LidContinuousClock(boot: boot, seconds: 10)
        XCTAssertThrowsError(try reopened.claimContinuation(intentID: intent, clock: clock) { $0 == retired })
        let claimed = try reopened.claimContinuation(intentID: intent, clock: clock) { $0 == replacement }
        XCTAssertEqual(claimed.phase, .resumeClaimed); XCTAssertNil(claimed.replacementToken)
        XCTAssertEqual(claimed.attempts, 1); XCTAssertEqual(claimed.sessionToken, retired)
        XCTAssertThrowsError(try reopened.claimContinuation(intentID: intent, clock: clock) { _ in true })
        XCTAssertFalse(try reopened.readiness(intentID: intent, clock: clock))
        let nextReplacement = UUID()
        let next = try store.markOutputConfirmed(intentID: intent, priorSessionToken: retired, replacementToken: nextReplacement)
        XCTAssertEqual(next.attempts, 1); XCTAssertEqual(next.replacementToken, nextReplacement)
    }
    func testOutputConfirmationCannotSkipClaimOrOverwriteCancellation() throws {
        let (_, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID(), replacement = UUID()
        try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: 1))
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: intent, priorSessionToken: token, replacementToken: replacement))
        try store.markVerified(intentID: intent, sessionToken: token) { _ in true }
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: intent, priorSessionToken: token, replacementToken: replacement))
        try store.claimResume(intentID: intent, sessionToken: token, clock: .init(boot: boot, seconds: 2)) { _ in true }
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: intent, priorSessionToken: token, replacementToken: token))
        try store.cancelPending()
        XCTAssertThrowsError(try store.markOutputConfirmed(intentID: intent, priorSessionToken: token, replacementToken: replacement))
    }
    func testConfirmedCancellationRetainsReplacementAndRejectsContinuation() throws {
        let (directory, store, intent, _, replacement, boot) = try confirmedFixture()
        try store.cancelPending(intentID: intent)
        let reopened = AutomaticRecoveryStore(directory: directory)
        XCTAssertEqual(try reopened.snapshot()?.phase, .cancelled)
        XCTAssertEqual(try reopened.snapshot()?.replacementToken, replacement)
        XCTAssertThrowsError(try reopened.claimContinuation(intentID: intent, clock: .init(boot: boot, seconds: 10)) { _ in true })
    }
    func testContinuationCallbackCannotResurrectCancelledRecord() throws {
        let (_, store, intent, _, replacement, boot) = try confirmedFixture()
        XCTAssertThrowsError(try store.claimContinuation(intentID: intent, clock: .init(boot: boot, seconds: 10)) { token in
            XCTAssertEqual(token, replacement)
            try store.cancelPending(intentID: intent)
            return true
        })
        XCTAssertEqual(try store.snapshot()?.phase, .cancelled)
    }
    func testReplacementTokenStructureIsValidatedOnLoad() throws {
        for kind in ["missingConfirmed", "presentClaimed", "sameAsRetired"] {
            let (_, store, _, retired, _, _) = try confirmedFixture()
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any])
            if kind == "missingConfirmed" { object.removeValue(forKey: "replacementToken") }
            if kind == "presentClaimed" { object["phase"] = "resumeClaimed" }
            if kind == "sameAsRetired" { object["replacementToken"] = retired.uuidString }
            try JSONSerialization.data(withJSONObject: object).write(to: store.url)
            XCTAssertThrowsError(try store.snapshot(), kind)
        }
    }

    func testPersistenceFailurePreventsCleanupPermissionOrAdmission() throws {
        let (directory, store) = try fixture(), intent = UUID(), token = UUID(), boot = UUID()
        let failing = AutomaticRecoveryStore(directory: directory, writer: { _, _ in throw AutomaticRecoveryStore.Failure.invalidRecord })
        XCTAssertThrowsError(try failing.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: 1)))
        XCTAssertNil(try store.snapshot())
        let initial = try store.beginAttempt(intentID: intent, sessionToken: token, reason: .lifecycle, clock: .init(boot: boot, seconds: 1))
        XCTAssertThrowsError(try failing.markVerified(intentID: intent, sessionToken: token, verifyCompletion: { _ in true }))
        XCTAssertEqual(try store.snapshot(), initial)
        try store.markVerified(intentID: intent, sessionToken: token) { _ in true }
        XCTAssertThrowsError(try failing.claimResume(intentID: intent, sessionToken: token, clock: .init(boot: boot, seconds: 2), verifyCompletion: { _ in true }))
        XCTAssertEqual(try store.snapshot()?.phase, .readyToResume)
    }
}
