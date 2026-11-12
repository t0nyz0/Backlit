import Foundation

/// A logo-only nits curve, never a display brightness setting. Keep the source
/// bounded to the requested level even if a native refresh resets the fade.
struct LogoSourceRecovery: Codable, Equatable {
    let original: [[Double]]
    let previous: [[Double]]
    let requested: [[Double]]
    static func curve(_ level: Double) -> [[Double]] {
        let nits = Effects.clamp(level) * 1000
        return [[0, nits], [Double(Float.greatestFiniteMagnitude), nits]]
    }
    static func isBoundedCurve(_ rows: [[Double]]) -> Bool {
        rows.count == 2 && rows.allSatisfy { $0.count == 2 } &&
        rows[0][0] == 0 && rows[1][0] == Double(Float.greatestFiniteMagnitude) &&
        rows[0][1].isFinite && (0...1000).contains(rows[0][1]) && rows[0][1] == rows[1][1]
    }
    var valid: Bool {
        LogoDevice.valid(original) && (LogoDevice.equivalent(previous, original) || Self.isBoundedCurve(previous)) && Self.isBoundedCurve(requested)
    }
    func owns(_ current: [[Double]]?) -> Bool {
        guard let current, valid else { return false }
        return [original, previous, requested].contains { LogoDevice.equivalent(current, $0) }
    }
}

final class IndependentLogoSource {
    private let original: [[Double]]
    private var expected: [[Double]]
    private(set) var installed = false
    var recovery: LogoSourceRecovery { .init(original: original, previous: expected, requested: LogoSourceRecovery.curve(0)) }
    init(original: [[Double]]) { self.original = original; expected = original }
    func validate(_ current: [[Double]]?) throws {
        guard let current, LogoDevice.valid(original), LogoDevice.equivalent(current, expected) else {
            throw RuntimeServices.failure("The logo brightness source changed. Recovery was retained.")
        }
    }
    func plan(_ level: Double, current: [[Double]]?) throws -> LogoSourceRecovery? {
        guard level.isFinite else { throw RuntimeServices.failure("Invalid logo brightness.") }
        try validate(current)
        let next = LogoSourceRecovery.curve(level)
        guard !installed || !LogoDevice.equivalent(expected, next) else { return nil }
        return .init(original: original, previous: expected, requested: next)
    }
    func didInstall(_ plan: LogoSourceRecovery) { expected = plan.requested; installed = true }
}
