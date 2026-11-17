import Foundation

/// Production adapter for token-bound, durable retries. It never treats an
/// absent journal as cleanup proof and does not modify the saved lid timer.
final class AutomaticFadeRecovery {
    let store: AutomaticRecoveryStore
    private let intent: () -> LidSessionIntent?
    private let clock: () -> LidContinuousClock?
    private let verify: (UUID) throws -> Bool
    private var claimMadeHere = false
    init(store: AutomaticRecoveryStore, intent: @escaping () -> LidSessionIntent?,
         clock: @escaping () -> LidContinuousClock? = LidContinuousClock.live,
         verify: @escaping (UUID) throws -> Bool) {
        self.store = store; self.intent = intent; self.clock = clock; self.verify = verify
    }
    private func context() throws -> (LidSessionIntent, LidContinuousClock) {
        guard let intent = intent(), intent.valid, !intent.blocked, let clock = clock(), clock.valid else {
            throw AutomaticRecoveryStore.Failure.mismatchedIntent
        }
        return (intent, clock)
    }
    func begin(token: UUID, reason: AutomaticRecoveryStore.Reason) throws {
        let (intent, clock) = try context()
        try store.beginAttempt(intentID: intent.id, sessionToken: token, reason: reason, clock: clock)
    }
    var intentWasWithdrawn: Bool { intent() == nil }
    func cleanupReady() throws -> Bool {
        let (intent, clock) = try context()
        return try store.cleanupReadiness(intentID: intent.id, clock: clock)
    }
    func verified(token: UUID) throws {
        let (intent, _) = try context()
        try store.markVerified(intentID: intent.id, sessionToken: token, verifyCompletion: verify)
    }
    func admit(allowWithdrawnIntent: Bool = false) throws -> Bool {
        guard let record = try store.snapshot() else { return true }
        if allowWithdrawnIntent, record.phase == .cancelled, intent() == nil { return true }
        let (intent, clock) = try context()
        guard record.intentID == intent.id else { throw AutomaticRecoveryStore.Failure.mismatchedIntent }
        if record.phase == .resumeClaimed {
            guard claimMadeHere else { throw AutomaticRecoveryStore.Failure.pending }
            return true
        }
        if record.phase == .outputConfirmed {
            try store.claimContinuation(intentID: intent.id, clock: clock, verifyCompletion: verify)
        } else {
            guard try store.readiness(intentID: intent.id, clock: clock) else { return false }
            try store.claimResume(intentID: intent.id, sessionToken: record.sessionToken, clock: clock, verifyCompletion: verify)
        }
        claimMadeHere = true
        // A proof callback may pump Off or replace the saved choice.
        guard self.intent()?.id == intent.id, self.intent()?.blocked == false else {
            throw AutomaticRecoveryStore.Failure.changed
        }
        return true
    }
    func cancelledHandbackVerified() throws -> Bool {
        guard let record = try store.snapshot(), record.phase == .cancelled else { return false }
        return try verify(record.replacementToken ?? record.sessionToken)
    }
    func outputConfirmed(token: UUID) throws {
        guard claimMadeHere, let record = try store.snapshot(), record.phase == .resumeClaimed else { return }
        let (intent, _) = try context()
        try store.markOutputConfirmed(intentID: intent.id, priorSessionToken: record.sessionToken, replacementToken: token)
        claimMadeHere = false
    }
    /// Used only before this process has admitted an owned session. A consumed
    /// claim without observed replacement output is never replayed on startup.
    func prepareStartup(eligible: () -> Bool, restore: (UUID) throws -> Void) throws -> Bool {
        guard let record = try store.snapshot() else { return true }
        let (intent, _) = try context()
        guard record.intentID == intent.id else { throw AutomaticRecoveryStore.Failure.mismatchedIntent }
        guard eligible() else { return false }
        switch record.phase {
        case .cancelled, .resumeClaimed: throw AutomaticRecoveryStore.Failure.pending
        case .outputConfirmed:
            return try admit() // Exact replacement receipt required by continuation.
        case .awaitingCleanup:
            guard try cleanupReady() else { return false }
            try begin(token: record.sessionToken, reason: record.reason)
            do { try restore(record.sessionToken) }
            catch {
                if (try store.snapshot()?.attempts ?? 3) >= AutomaticRecoveryStore.attemptLimit { throw error }
                return false
            }
            guard eligible(), self.intent()?.id == intent.id, self.intent()?.blocked == false else { return false }
            try verified(token: record.sessionToken)
            return false // Admission is a separate subsequent turn.
        case .readyToResume:
            let (_, clock) = try context()
            guard try store.readiness(intentID: intent.id, clock: clock) else { return false }
            try restore(record.sessionToken) // Also retire the outer logo mapping lease.
            guard eligible(), self.intent()?.id == intent.id, self.intent()?.blocked == false else { return false }
            return try admit()
        }
    }
    func clearAfterExplicitRecovery() throws {
        try store.clearAfterExplicitRecovery()
        claimMadeHere = false
    }

}

@MainActor struct AutomaticRecoveryStartupEnvironment {
    let recovery: AutomaticFadeRecovery
    let eligible: () -> Bool
    let restore: (UUID) throws -> Void
    var ownedToken: () -> UUID? = { nil }
}
