import Foundation

enum FadeApplyResult: Equatable { case applied, waiting, paused }

protocol FadeEffectSession: AnyObject {
    var needsAnimation: Bool { get }
    func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult
    func restore() throws
}

/// Owns only the animation session, not the logo lease or saved native mapping.
/// A normal lid-policy pause must verify cleanup before forgetting the session.
final class FadeSessionCoordinator {
    private let physicalLid: () -> Bool?
    private let makeSession: (Bool) throws -> any FadeEffectSession
    private var session: (any FadeEffectSession)?
    private var recoveryRequired = false
    var needsAnimation: Bool { session?.needsAnimation == true }
    var hasSession: Bool { session != nil }
    init(physicalLid: @escaping () -> Bool?, makeSession: @escaping (Bool) throws -> any FadeEffectSession) {
        self.physicalLid = physicalLid; self.makeSession = makeSession
    }
    func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult {
        if recoveryRequired {try restore()}
        guard let lid = physicalLid() else { throw RuntimeServices.failure("Physical lid state is unavailable.") }
        if lid && !closedLidRequested { try restore(); return .paused }
        if session == nil { session = try makeSession(closedLidRequested) }
        guard let session else { throw RuntimeServices.failure("Logo animation session is unavailable.") }
        let result: FadeApplyResult
        do {
            result = try session.apply(brightness, closedLidRequested: closedLidRequested, frameInterval: frameInterval)
        } catch {
            // A close can race the initial policy read or helper shutdown.
            // Only successful token-verified cleanup converts it into a pause.
            if physicalLid() == true && !closedLidRequested { try restore(); return .paused }
            throw error
        }
        if result == .paused { try restore() }
        return result
    }
    func restore() throws {
        guard let session else { return }
        recoveryRequired = true
        try session.restore()
        self.session = nil
        recoveryRequired = false
    }
}
