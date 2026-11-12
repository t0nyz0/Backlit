import Foundation
import OSLog

enum FadeApplyResult: Equatable { case applied, waiting, paused }

/// Only known lifecycle/output interruptions qualify for automatic retirement.
/// Ownership, journal integrity and generic hardware failures remain errors.
enum FadeSessionInterruption: LocalizedError {
    case lifecycle, outputTimeout(String)
    /// The lid opened or closed, so the session must be replaced by one of the
    /// other kind. This is expected behavior, not a fault.
    case sourceMode
    var errorDescription: String? {
        switch self {
        case .lifecycle: return "Logo control is recovering after a system transition."
        case .sourceMode: return "Logo control is switching between open-lid and closed-lid lighting."
        case .outputTimeout(let message): return message
        }
    }
}

protocol FadeEffectSession: AnyObject {
    var needsAnimation: Bool { get }
    var ownsIndependentSource: Bool { get }
    func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult
    func restore() throws
}

extension FadeEffectSession { var ownsIndependentSource: Bool { false } }

/// Owns only the animation session, not the logo lease or saved native mapping.
/// A normal lid-policy pause must verify cleanup before forgetting the session.
final class FadeSessionCoordinator {
    private let recoveryLogger = Logger(subsystem: "local.backlit", category: "recovery")
    private let physicalLid: () -> Bool?
    private let makeSession: (Bool) throws -> any FadeEffectSession
    private var session: (any FadeEffectSession)?
    private var recoveryRequired = false
    private let now: () -> Double
    private var retries = 0
    private var retryAfter: Double?
    private var healthySince: Double?
    private var terminalFailure: Error?
    private(set) var automaticRecoveryPending = false
    var needsAnimation: Bool { retryAfter != nil || session?.needsAnimation == true }
    var hasSession: Bool { session != nil }
    var ownsIndependentSource: Bool { session?.ownsIndependentSource == true }
    init(physicalLid: @escaping () -> Bool?, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, makeSession: @escaping (Bool) throws -> any FadeEffectSession) {
        self.physicalLid = physicalLid; self.now = now; self.makeSession = makeSession
    }
    func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult {
        if let terminalFailure { throw terminalFailure }
        if recoveryRequired {try retire()}
        guard let lid = physicalLid() else { throw RuntimeServices.failure("Physical lid state is unavailable.") }
        if lid && !closedLidRequested { try retire(); return .paused }
        if let deadline = retryAfter {
            let time = now()
            guard time.isFinite, time >= 0 else { throw RuntimeServices.failure("Logo recovery clock is unavailable.") }
            if time < deadline { return .waiting }
            retryAfter = nil
        }
        if session == nil { session = try makeSession(closedLidRequested) }
        guard let session else { throw RuntimeServices.failure("Logo animation session is unavailable.") }
        let result: FadeApplyResult
        do {
            result = try session.apply(brightness, closedLidRequested: closedLidRequested, frameInterval: frameInterval)
        } catch {
            // A close can race the initial policy read or helper shutdown.
            // Only successful token-verified cleanup converts it into a pause.
            if physicalLid() == true && !closedLidRequested { try retire(); return .paused }
            guard let interruption = error as? FadeSessionInterruption else { throw error }
            healthySince = nil
            if case .sourceMode = interruption {
                // Opening or closing the lid is not a failure. Retire the old
                // session with the usual verified cleanup and wait the same
                // one second as a first retry, but never spend the bounded
                // failure budget on it.
                try retire()
                let time = now()
                guard time.isFinite, time >= 0 else { throw RuntimeServices.failure("Logo recovery clock is unavailable.") }
                retryAfter = time + 1
                recoveryLogger.notice("Lid position changed; replacing the light session after verified retirement.")
                return .waiting
            }
            automaticRecoveryPending = true
            // Restoration must succeed before a replacement can be considered.
            // A failed restore retains the old session and its recovery gate.
            try retire()
            guard retries < 3 else {
                terminalFailure = error
                recoveryLogger.error("Automatic fade recovery exhausted its retry budget; light control stopped.")
                throw error
            }
            let time = now()
            guard time.isFinite, time >= 0 else { throw RuntimeServices.failure("Logo recovery clock is unavailable.") }
            retryAfter = time + pow(2, Double(retries))
            retries += 1
            recoveryLogger.notice("Verified fade retirement; scheduling recovery attempt \(self.retries).")
            return .waiting
        }
        if result == .applied {
            if automaticRecoveryPending { recoveryLogger.notice("Automatic fade recovery confirmed a successful output frame.") }
            automaticRecoveryPending = false
            let time = now()
            if healthySince == nil { healthySince = time }
            if let start = healthySince, time.isFinite, time >= start, time - start >= 60 { retries = 0 }
        } else { healthySince = nil }
        if result == .paused { try retire() }
        return result
    }
    /// Manual restoration must clear a retired coordinator's failure latch,
    /// but only after any remaining durable recovery has been verified.
    func restore(recoverPending: () throws -> Void) throws {
        if !hasSession { try recoverPending() }
        try restore()
    }
    func restore() throws {
        try retire()
        retries = 0; retryAfter = nil; healthySince = nil; terminalFailure = nil; automaticRecoveryPending = false
    }
    private func retire() throws {
        healthySince = nil
        guard let session else { return }
        recoveryRequired = true
        try session.restore()
        self.session = nil
        recoveryRequired = false
    }
}
