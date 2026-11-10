import Foundation

struct LidSessionPolicy {
    static func validDuration(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds >= 0 && seconds <= 604800
    }
    static func timedOut(closedAt: Double?, now: Double, duration: Double) -> Bool {
        guard duration > 0, let closedAt else { return false }
        return now - closedAt >= duration
    }
    static func eligible(exhausted: Bool, externalPower: Bool, battery: Double,
                         lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
        !exhausted && (externalPower || battery > 0.2) && !lowPower &&
            thermal != .serious && thermal != .critical
    }
}
