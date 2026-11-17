import Foundation

/// A durable admission ledger, not proof that hardware cleanup succeeded.
/// The caller must verify the exact retired fade token before each admission.
/// No timer or native state is changed here; explicit recovery is the only reset.
final class AutomaticRecoveryStore {
    enum Reason: String, Codable { case lifecycle, outputTimeout }
    enum Phase: String, Codable { case awaitingCleanup, readyToResume, resumeClaimed, outputConfirmed, cancelled }
    struct Record: Codable, Equatable {
        let version: Int
        let intentID: UUID
        let sessionToken: UUID
        let reason: Reason
        let boot: UUID
        let startedAt: Double
        let retryAfter: Double
        let attempts: Int
        var phase: Phase
        var replacementToken: UUID? = nil
        private var validReplacement: Bool {
            if let replacementToken, replacementToken == sessionToken { return false }
            switch phase {
            case .outputConfirmed: return replacementToken != nil
            case .cancelled: return true // Preserve the last bound token on withdrawal.
            default: return replacementToken == nil
            }
        }
        var valid: Bool {
            version == 1 && validReplacement && (1...AutomaticRecoveryStore.attemptLimit).contains(attempts) &&
                startedAt.isFinite && startedAt >= 0 && retryAfter.isFinite &&
                abs(retryAfter - startedAt - pow(2, Double(attempts - 1))) <= 0.000_001
        }
    }
    enum Failure: LocalizedError {
        case invalidRecord, mismatchedIntent, mismatchedSession, invalidClock, exhausted, pending, unverified, changed, notReady
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "The saved automatic recovery record is invalid. Restore Light before retrying."
            case .mismatchedIntent: return "The saved recovery belongs to a different closed-lid choice."
            case .mismatchedSession: return "The saved recovery belongs to a different light session."
            case .invalidClock: return "Automatic recovery timing could not be verified."
            case .exhausted: return "Automatic light recovery stopped after three attempts. Restore Light before retrying."
            case .pending: return "The previous automatic recovery has not been admitted."
            case .unverified: return "The exact previous light session's cleanup is not verified."
            case .changed: return "The automatic recovery choice changed during verification."
            case .notReady: return "Automatic light recovery is not ready to resume."
            }
        }
    }
    static let attemptLimit = 3
    let directory: URL
    var url: URL { directory.appendingPathComponent("automatic-recovery.json") }
    private let writer: (Data, URL) throws -> Void
    init(directory: URL, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory; self.writer = writer
    }
    func snapshot() throws -> Record? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        let record: Record
        do { record = try JSONDecoder().decode(Record.self, from: data) }
        catch { throw Failure.invalidRecord }
        guard record.valid else { throw Failure.invalidRecord }
        return record
    }
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let lease = try FileLease(url: directory.appendingPathComponent("automatic-recovery.lock"))
        return try withExtendedLifetime(lease) { try body() }
    }
    private func persist(_ record: Record) throws {
        guard record.valid else { throw Failure.invalidRecord }
        try writer(JSONEncoder().encode(record), url)
        guard try snapshot() == record else { throw Failure.invalidRecord }
    }
    private func validate(_ record: Record, intentID: UUID, clock: LidContinuousClock) throws {
        guard record.intentID == intentID else { throw Failure.mismatchedIntent }
        // Reboot is not evidence of native handback and cannot replenish budget.
        guard clock.valid, clock.boot == record.boot, clock.seconds >= record.startedAt,
              record.retryAfter - clock.seconds <= pow(2, Double(record.attempts - 1)) + 0.000_001 else { throw Failure.invalidClock }
    }
    @discardableResult func beginAttempt(intentID: UUID, sessionToken: UUID, reason: Reason,
                                         clock: LidContinuousClock) throws -> Record {
        try withLock {
            guard clock.valid else { throw Failure.invalidClock }
            let old = try snapshot()
            if let old {
                try validate(old, intentID: intentID, clock: clock)
                if old.sessionToken == sessionToken {
                    guard old.reason == reason, old.phase == .awaitingCleanup else { throw Failure.mismatchedSession }
                    guard clock.seconds >= old.retryAfter else { throw Failure.notReady }
                } else {
                    if old.phase == .outputConfirmed {
                        guard old.replacementToken == sessionToken else { throw Failure.mismatchedSession }
                    } else {
                        guard old.phase == .resumeClaimed else { throw Failure.pending }
                    }
                }
                guard old.attempts < Self.attemptLimit else { throw Failure.exhausted }
            }
            let attempts = (old?.attempts ?? 0) + 1
            let record = Record(version: 1, intentID: intentID, sessionToken: sessionToken, reason: reason,
                                boot: clock.boot, startedAt: clock.seconds,
                                retryAfter: clock.seconds + pow(2, Double(attempts - 1)), attempts: attempts, phase: .awaitingCleanup)
            try persist(record) // Must succeed before caller performs cleanup.
            return record
        }
    }
    @discardableResult func markVerified(intentID: UUID, sessionToken: UUID,
                                        verifyCompletion: (UUID) throws -> Bool) throws -> Record {
        guard let original = try snapshot() else { throw Failure.unverified }
        guard original.intentID == intentID else { throw Failure.mismatchedIntent }
        guard original.sessionToken == sessionToken else { throw Failure.mismatchedSession }
        guard original.phase == .awaitingCleanup || original.phase == .readyToResume else { throw Failure.pending }
        // The callback may pump user actions. Never hold a lock across it, and
        // never restore a record deleted or replaced while it was running.
        guard try verifyCompletion(sessionToken) else { throw Failure.unverified }
        return try withLock {
            guard try snapshot() == original else { throw Failure.changed }
            var record = original; record.phase = .readyToResume
            try persist(record)
            return record
        }
    }
    func cleanupReadiness(intentID: UUID, clock: LidContinuousClock) throws -> Bool {
        guard let record = try snapshot() else { return false }
        try validate(record, intentID: intentID, clock: clock)
        return record.phase == .awaitingCleanup && clock.seconds >= record.retryAfter
    }
    func readiness(intentID: UUID, clock: LidContinuousClock) throws -> Bool {
        guard let record = try snapshot() else { return false }
        try validate(record, intentID: intentID, clock: clock)
        return record.phase == .readyToResume && clock.seconds >= record.retryAfter
    }
    /// Persist consumption before starting any replacement session. The caller
    /// must recheck its Off/Quit, timer and native safety gates after this call.
    @discardableResult func claimResume(intentID: UUID, sessionToken: UUID, clock: LidContinuousClock,
                                       verifyCompletion: (UUID) throws -> Bool) throws -> Record {
        guard let original = try snapshot() else { throw Failure.notReady }
        try validate(original, intentID: intentID, clock: clock)
        guard original.sessionToken == sessionToken else { throw Failure.mismatchedSession }
        guard original.phase == .readyToResume, clock.seconds >= original.retryAfter else { throw Failure.notReady }
        guard try verifyCompletion(sessionToken) else { throw Failure.unverified }
        return try withLock {
            guard try snapshot() == original else { throw Failure.changed }
            var record = original; record.phase = .resumeClaimed
            try persist(record)
            return record
        }
    }
    /// The caller invokes this only after an actually applied frame from the
    /// replacement session. This records output, not proof of later handback.
    @discardableResult func markOutputConfirmed(intentID: UUID, priorSessionToken: UUID,
                                               replacementToken: UUID) throws -> Record {
        try withLock {
            guard var record = try snapshot() else { throw Failure.notReady }
            guard record.intentID == intentID else { throw Failure.mismatchedIntent }
            guard record.sessionToken == priorSessionToken, replacementToken != priorSessionToken else { throw Failure.mismatchedSession }
            if record.phase == .outputConfirmed {
                guard record.replacementToken == replacementToken else { throw Failure.mismatchedSession }
                return record
            }
            guard record.phase == .resumeClaimed else { throw Failure.pending }
            record.phase = .outputConfirmed; record.replacementToken = replacementToken
            try persist(record)
            return record
        }
    }
    /// A later launch may continue only after the exact confirmed replacement
    /// was handed back. This consumes admission without earning another retry.
    /// Caller additionally verifies no remaining journals and all safety gates.
    @discardableResult func claimContinuation(intentID: UUID, clock: LidContinuousClock,
                                              verifyCompletion: (UUID) throws -> Bool) throws -> Record {
        guard let original = try snapshot() else { throw Failure.notReady }
        try validate(original, intentID: intentID, clock: clock)
        guard original.phase == .outputConfirmed, let replacement = original.replacementToken else { throw Failure.notReady }
        guard try verifyCompletion(replacement) else { throw Failure.unverified }
        return try withLock {
            guard try snapshot() == original else { throw Failure.changed }
            var record = original; record.phase = .resumeClaimed; record.replacementToken = nil
            try persist(record)
            return record
        }
    }
    /// Withdrawal revokes admission but retains the failed token and budget.
    /// Cleanup may still be outstanding; Off/Quit must never erase its proof.
    func cancelPending(intentID: UUID? = nil) throws {
        try withLock {
            guard var record = try snapshot() else { return }
            if let intentID, record.intentID != intentID { throw Failure.mismatchedIntent }
            guard record.phase != .cancelled else { return }
            record.phase = .cancelled
            try persist(record)
        }
    }
    func clearAfterExplicitRecovery(intentID: UUID? = nil) throws {
        try withLock {
            if let intentID, let record = try snapshot(), record.intentID != intentID { throw Failure.mismatchedIntent }
            do { try FileManager.default.removeItem(at: url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { return }
        }
    }
}
