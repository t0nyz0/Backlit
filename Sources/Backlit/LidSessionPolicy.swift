import Foundation

struct LidSessionPolicy {
    static func validDuration(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= LidSessionDuration.maximumSeconds
    }
    static func timedOut(closedAt: Double?, now: Double, duration: Double) -> Bool {
        guard validDuration(duration), now.isFinite, now >= 0 else { return true }
        guard let closedAt else { return false }
        guard closedAt.isFinite, closedAt >= 0, now >= closedAt else { return true }
        return now - closedAt >= duration
    }
    static func eligible(exhausted: Bool, externalPower: Bool, battery: Double,
                         lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        !exhausted && (externalPower || battery > 0.2) && !lowPower &&
            thermal != .serious && thermal != .critical
    }
}

/// Bounded compatibility path for helper callers without a saved intent.
struct LidLegacyContinuousTimer {
    let duration: Double
    private var started: LidContinuousClock?
    private var previous: LidContinuousClock?
    private var invalid = false
    init(duration: Double) { self.duration = duration }
    mutating func permits(closed: Bool, clock: LidContinuousClock?) -> Bool {
        guard LidSessionPolicy.validDuration(duration), let clock, clock.valid else { invalid = true; return false }
        if !closed { started = nil; previous = clock; invalid = false; return true }
        if let previous, previous.boot != clock.boot || clock.seconds < previous.seconds { invalid = true }
        previous = clock
        guard !invalid else { return false }
        if started == nil { started = clock }
        guard let started, started.boot == clock.boot else { return false }
        return !LidSessionPolicy.timedOut(closedAt: started.seconds, now: clock.seconds, duration: duration)
    }
}
