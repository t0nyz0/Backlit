import Foundation
import CoreGraphics
import Darwin

/// A saved choice is not proof that a helper is running or safe to start.
struct LidSessionIntent: Codable, Equatable {
    static let preferenceKey = "lid.requestedSession.v1"
    let version: Int
    let id: UUID
    let durationSeconds: Double
    var blocked: Bool
    // Optional for v1 compatibility. A missing cause is an unknown legacy
    // pause, never an assertion that the old failure was transient.
    var pause: LidSavedPause?

    init(duration: LidSessionDuration, id: UUID = UUID()) {
        version = 1; self.id = id; durationSeconds = duration.durationSeconds; blocked = false
    }
    init?(id: UUID, durationSeconds: Double) {
        guard LidSessionPolicy.validDuration(durationSeconds) else { return nil }
        version = 1; self.id = id; self.durationSeconds = durationSeconds; blocked = false
    }
    var valid: Bool {
        version == 1 && LidSessionPolicy.validDuration(durationSeconds) &&
            (pause?.valid ?? true) && (blocked || pause == nil)
    }
    var savedPause: LidSavedPause? { blocked ? pause ?? .init(reason: .legacyUnknown) : nil }
    static func load(_ defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: preferenceKey),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.valid else { return nil }
        return value
    }
    func save(_ defaults: UserDefaults) throws {
        guard valid else { throw RuntimeServices.failure("The saved closed-lid choice is invalid.") }
        defaults.set(try JSONEncoder().encode(self), forKey: Self.preferenceKey)
    }
}

struct LidSavedPause: Codable, Equatable {
    enum Reason: String, Codable { case legacyUnknown, interruptedCleanup, hardFault }
    var reason: Reason
    var attempts = 0
    var retryBoot: UUID?
    var retryAfter: Double?
    var detail: String?
    static let attemptLimit = 3
    var valid: Bool {
        (0...Self.attemptLimit).contains(attempts) &&
            ((retryBoot == nil && retryAfter == nil) ||
             (retryBoot != nil && retryAfter.map { $0.isFinite && $0 >= 0 } == true))
    }
    var canRetry: Bool { reason != .hardFault && attempts < Self.attemptLimit }
    var needsQualifiedHandback: Bool { reason == .legacyUnknown || reason == .interruptedCleanup }
    static let unconfirmedStatus = "Recovery unconfirmed. Your closed-lid choice is saved and remains paused. Review recovery in Settings."
    func hasImpossibleBackoff(clock: LidContinuousClock) -> Bool {
        guard clock.valid, retryBoot == clock.boot, let retryAfter else { return false }
        let maximumDelay = attempts > 0 ? pow(2, Double(attempts - 1)) : 0
        // Continuous time includes sleep and cannot restart within one boot.
        // A larger remaining delay means saved timing or the current clock is
        // untrustworthy. Never wait indefinitely or reset the retry budget.
        return retryAfter - clock.seconds > maximumDelay + 0.000_001
    }
    func ready(clock: LidContinuousClock) -> Bool {
        canRetry && clock.valid && (retryBoot != clock.boot || retryAfter.map { clock.seconds >= $0 } != false)
    }
    var status: String {
        if reason == .hardFault { return detail ?? "Paused after an error. Restore your light, then turn this setting off and on to retry." }
        if needsQualifiedHandback { return Self.unconfirmedStatus }
        if attempts >= Self.attemptLimit { return "Automatic safety checks stopped after three attempts. Restore your light, then turn this setting off and on to retry." }
        if let detail { return detail }
        return "Remembered. Waiting to verify the previous session before reconnecting."
    }
}

enum LidPauseVerification {
    case verified
    case handbackUnconfirmed
    case retryLater(String)
    case requiresRepair(String)
}

/// A fixture seam for the bounded admission state machine, not a handback
/// implementation. Production has no qualified handback provider and must not
/// enable automatic clearance from journal absence or native policy caches.
@MainActor struct LidPauseRecoveryEnvironment {
    var clock: () -> LidContinuousClock?
    var eligible: () -> Bool
    var verify: () throws -> LidPauseVerification
    var allowsAutomaticClearance = false
    func available(inPreview preview: Bool) -> Bool { preview && allowsAutomaticClearance }
}

struct LidContinuousClock: Equatable {
    let boot: UUID
    let seconds: Double
    var valid: Bool { seconds.isFinite && seconds >= 0 }

    /// Unlike wall time or mach_absolute_time, this clock includes sleep.
    /// kern.bootsessionuuid identifies a boot, not a sleep/wake cycle.
    static func live() -> Self? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 128 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let boot = UUID(uuidString: String(cString: bytes)) else { return nil }
        var scale = mach_timebase_info_data_t()
        guard mach_timebase_info(&scale) == KERN_SUCCESS, scale.denom != 0 else { return nil }
        let seconds = Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
        let result = Self(boot: boot, seconds: seconds)
        return result.valid ? result : nil
    }
}

struct LidTimerCheckpoint: Codable, Equatable {
    let version: Int
    let intent: UUID
    let boot: UUID
    let duration: Double
    let closedAt: Double?
    let deadline: Double?

    static func open(_ intent: LidSessionIntent, clock: LidContinuousClock) -> Self {
        .init(version: 1, intent: intent.id, boot: clock.boot, duration: intent.durationSeconds, closedAt: nil, deadline: nil)
    }
    static func closed(_ intent: LidSessionIntent, clock: LidContinuousClock) -> Self {
        .init(version: 1, intent: intent.id, boot: clock.boot, duration: intent.durationSeconds,
              closedAt: clock.seconds, deadline: clock.seconds + intent.durationSeconds)
    }
    func valid(for intent: LidSessionIntent, clock: LidContinuousClock) -> Bool {
        guard version == 1, self.intent == intent.id, boot == clock.boot, duration == intent.durationSeconds,
              duration > 0, LidSessionPolicy.validDuration(duration), clock.valid else { return false }
        switch (closedAt, deadline) {
        case (nil, nil): return true
        case let (start?, end?):
            return start.isFinite && end.isFinite && start >= 0 && clock.seconds >= start && end > start &&
                abs((end - start) - duration) <= 0.000_001
        default: return false
        }
    }
}

/// One helper writes its token's checkpoint. Replacement helpers only start
/// after previous cleanup is verified, and reuse that same token/deadline.
struct LidTimerCheckpointStore {
    let directory: URL
    func url(_ intent: UUID) -> URL { directory.appendingPathComponent("lid-timer-\(intent.uuidString).json") }
    func read(_ intent: UUID) -> LidTimerCheckpoint? {
        guard let bytes = try? Data(contentsOf: url(intent)), bytes.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(LidTimerCheckpoint.self, from: bytes)
    }
    func write(_ checkpoint: LidTimerCheckpoint) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url(checkpoint.intent), options: .atomic)
    }
}

enum LidTimerDecision: Equatable {
    case ready(LidTimerCheckpoint?)
    case expired
    case needsOpen
    case unavailable
}

enum LidIntentPolicy {
    /// A verified open-to-closed transition or a new explicit On may establish
    /// a cycle. Relaunch alone cannot. Existing expired cycles stay expired.
    static func timer(intent: LidSessionIntent, checkpoint: LidTimerCheckpoint?,
                      clock: LidContinuousClock?, closed: Bool?, newCycle: Bool = false) -> LidTimerDecision {
        guard intent.valid, !intent.blocked, let closed else { return .unavailable }
        if intent.durationSeconds == 0 { return .ready(nil) }
        guard let clock, clock.valid else { return .unavailable }
        if !closed { return .ready(.open(intent, clock: clock)) }
        if newCycle {
            let fresh = LidTimerCheckpoint.closed(intent, clock: clock)
            return fresh.valid(for: intent, clock: clock) ? .ready(fresh) : .unavailable
        }
        guard let checkpoint, checkpoint.valid(for: intent, clock: clock), let end = checkpoint.deadline else { return .needsOpen }
        return clock.seconds < end ? .ready(checkpoint) : .expired
    }
}

/// The live helper uses this exact checkpoint-before-grant ordering.
final class LidTimerMonitor {
    private let intent: LidSessionIntent
    private let read: () -> LidTimerCheckpoint?
    private let write: (LidTimerCheckpoint) throws -> Void
    private var observedOpen = false
    private var previousClock: LidContinuousClock?
    private var clockRegressed = false
    init(intent: LidSessionIntent, read: @escaping () -> LidTimerCheckpoint?,
         write: @escaping (LidTimerCheckpoint) throws -> Void) {
        self.intent = intent; self.read = read; self.write = write
    }
    func update(closed: Bool, clock: LidContinuousClock?) throws -> Bool {
        if let clock, let previousClock, clock.boot != previousClock.boot || clock.seconds < previousClock.seconds { clockRegressed = true }
        if !closed, clock?.valid == true { clockRegressed = false }
        let old = read()
        let decision = LidIntentPolicy.timer(intent: intent, checkpoint: old,
            clock: clockRegressed ? nil : clock, closed: closed, newCycle: closed && observedOpen)
        observedOpen = !closed
        previousClock = clock
        guard case let .ready(checkpoint) = decision else { return false }
        if let checkpoint, checkpoint != old { try write(checkpoint) }
        return true
    }
}

struct LidResumeSafety {
    let preview: Bool
    let enabled: Bool
    let owned: Bool
    let cleanupClear: Bool
    let awake: Bool
    let unlocked: Bool
    let externalPower: Bool
    let battery: Double?
    let lowPower: Bool
    let thermal: ProcessInfo.ThermalState

    var eligible: Bool {
        guard !preview, enabled, owned, cleanupClear, awake, unlocked,
              let battery, battery.isFinite, (0...1).contains(battery) else { return false }
        return LidSessionPolicy.eligible(exhausted: false, externalPower: externalPower,
            battery: battery, lowPower: lowPower, thermal: thermal)
    }
    static func sessionUnlocked() -> Bool {
        func bool(_ value: Any?) -> Bool? {
            guard let number = value as? NSNumber, [0.0, 1.0].contains(number.doubleValue) else { return nil }
            return number.boolValue
        }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              bool(session["kCGSSessionOnConsoleKey"]) == true,
              bool(session["kCGSessionLoginDoneKey"]) == true else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] {
            guard let value = bool(locked) else { return false }
            return !value
        }
        return true // macOS omits the lock key in an unlocked session.
    }
}

/// Injected dependencies make upgrade/relaunch and ordering tests capture-free.
@MainActor struct LidIntentEnvironment {
    var clock: () -> LidContinuousClock?
    var closed: () -> Bool?
    var safety: () -> LidResumeSafety
    var checkpoints: LidTimerCheckpointStore
    var start: (LidSessionIntent, URL) throws -> any LidWatcherProcess
}

@MainActor final class LidIntentController {
    enum Resume {
        case started(LidSessionIntent, any LidWatcherProcess, URL)
        case paused(String)
        case off
    }
    let defaults: UserDefaults
    private var verifyingPause = false
    private let writeIntent: (LidSessionIntent) throws -> Void
    init(defaults: UserDefaults, writeIntent: ((LidSessionIntent) throws -> Void)? = nil) {
        self.defaults = defaults
        self.writeIntent = writeIntent ?? { try $0.save(defaults) }
    }
    private func persist(_ value: LidSessionIntent) throws {
        try writeIntent(value)
        guard intent == value else { throw RuntimeServices.failure("The saved closed-lid safety state could not be recorded.") }
        // UserDefaults provides retained preferences across normal relaunches.
        // This readback is not an fsync guarantee against sudden power loss.
    }
    var intent: LidSessionIntent? { LidSessionIntent.load(defaults) }
    func disable() { defaults.removeObject(forKey: LidSessionIntent.preferenceKey) }
    @discardableResult func block(reason: LidSavedPause.Reason = .hardFault, detail: String? = nil) -> Bool {
        guard var intent else { return true }
        intent.blocked = true
        // Do not reset a durable budget on repeated callbacks or relaunch.
        var pause = intent.savedPause ?? .init(reason: reason)
        if reason == .hardFault || pause.reason != .hardFault { pause.reason = reason }
        pause.detail = detail
        intent.pause = pause
        do { try persist(intent); return true } catch { return false }
    }
    func recordCleanupAttempt(clock: LidContinuousClock?) throws {
        guard var intent else { return }
        guard var pause = intent.pause, pause.reason == .interruptedCleanup, pause.canRetry else {
            throw RuntimeServices.failure("The saved closed-lid failure is not eligible for automatic cleanup.")
        }
        pause.attempts = min(LidSavedPause.attemptLimit, pause.attempts + 1)
        if let clock, clock.valid {
            pause.retryBoot = clock.boot; pause.retryAfter = clock.seconds + pow(2, Double(pause.attempts - 1))
        }
        intent.pause = pause; try persist(intent)
    }
    /// Only verifies/clears the latch. Normal ownership, timer and helper
    /// admission still run afterwards and recheck the same saved intent.
    @discardableResult func recoverSavedPause(environment: LidPauseRecoveryEnvironment) throws -> Bool {
        guard environment.allowsAutomaticClearance, !verifyingPause,
              var intent, var pause = intent.savedPause else { return false }
        let originalIntent = intent
        verifyingPause = true
        defer { verifyingPause = false }
        guard let clock = environment.clock(), clock.valid, self.intent == intent else { return false }
        if pause.canRetry && pause.hasImpossibleBackoff(clock: clock) {
            pause.reason = .hardFault
            pause.detail = "Saved recovery timing could not be verified. Restore your light, then turn closed-lid lighting off and on to retry."
            intent.pause = pause
            try persist(intent)
            return false
        }
        guard pause.ready(clock: clock),
              environment.eligible(), self.intent == intent else { return false }
        pause.attempts += 1
        pause.retryBoot = clock.boot; pause.retryAfter = clock.seconds + pow(2, Double(pause.attempts - 1))
        pause.detail = nil
        intent.pause = pause
        try persist(intent) // Recorded *before* a potentially reentrant check.
        let result: LidPauseVerification
        do { result = try environment.verify() }
        catch { result = .requiresRepair("Safety verification failed: \(error.localizedDescription) Restore your light before retrying.") }
        guard self.intent == intent else { return false }
        switch result {
        case .handbackUnconfirmed:
            // Read-only preflight is not a recovery attempt or a handback.
            // Retain exactly the original choice/budget; no retry is earned.
            try persist(originalIntent)
            return false
        case .verified:
            guard let after = environment.clock(), after.valid, after.boot == clock.boot,
                  after.seconds >= clock.seconds, environment.eligible(), self.intent == intent else { return false }
            intent.blocked = false; intent.pause = nil
            try persist(intent)
            return true
        case .retryLater(let detail): pause.detail = detail
        case .requiresRepair(let detail): pause.reason = .hardFault; pause.detail = detail
        }
        intent.pause = pause; try persist(intent)
        return false
    }
    func enable(duration: LidSessionDuration, environment: LidIntentEnvironment) throws {
        let intent = LidSessionIntent(duration: duration)
        try persist(intent)
        // Only this explicit action may create a cycle while already closed.
        if case let .ready(checkpoint) = LidIntentPolicy.timer(intent: intent, checkpoint: nil,
            clock: environment.clock(), closed: environment.closed(), newCycle: true), let checkpoint {
            do { try environment.checkpoints.write(checkpoint) }
            catch { block(); throw error }
        }
    }
    func resume(environment: LidIntentEnvironment) throws -> Resume {
        guard let intent else { return .off }
        guard !intent.blocked else { return .paused(intent.savedPause!.status) }
        guard environment.safety().eligible else { return .paused("Remembered. Waiting for your Mac and light to be ready.") }
        let old = environment.checkpoints.read(intent.id)
        switch LidIntentPolicy.timer(intent: intent, checkpoint: old,
            clock: environment.clock(), closed: environment.closed()) {
        case .expired: return .paused("Timer finished. Reopen the lid to begin another timed session.")
        case .needsOpen: return .paused("Remembered. Open the lid before starting another timed session.")
        case .unavailable: return .paused("Remembered. Waiting for a verified lid and timer state.")
        case let .ready(checkpoint):
            do {
                if let checkpoint, checkpoint != old { try environment.checkpoints.write(checkpoint) }
                // A safety callback or explicit Off may withdraw the choice.
                guard self.intent == intent, environment.safety().eligible, self.intent == intent else { return .off }
                let lease = environment.checkpoints.directory.appendingPathComponent("lid-lease-\(UUID().uuidString)")
                let process = try environment.start(intent, lease)
                return .started(intent, process, lease)
            } catch { if self.intent?.id == intent.id { block() }; throw error }
        }
    }
}
