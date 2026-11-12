import Foundation

/// Read-only preflight only. Neither absent journals nor these native-policy
/// snapshots observe remaining synthetic overrides or fence late requests.
/// This inspector cannot qualify native handback or clear a saved pause.
struct LidPauseRecoveryVerifier {
    struct Snapshot: Equatable {
        let context: FadeSafetyContext
        let keyboards: [UInt64: Int]
        let mapping: [[Double]]
        var safe: Bool {
            !context.sleeping && !context.locked && !keyboards.isEmpty &&
                keyboards.values.allSatisfy { (0...6).contains($0) } && LogoDevice.valid(mapping)
        }
    }
    let directory: URL
    let snapshot: () throws -> Snapshot?

    func verify() throws -> LidPauseVerification {
        // An empty historical lease file is not an owner. Only the process
        // lock matters; journal absence is checked while both locks are held.
        let owner = try FileLease(url: directory.appendingPathComponent("logo.lock"))
        return try withExtendedLifetime(owner) {
            let result = try ClosedEffectSession.locked(directory: directory, wait: false) {
                guard journalsAbsent else { return LidPauseVerification.requiresRepair(
                    "A previous session still has a recovery record. Restore Light can request restoration; it does not confirm native handback.") }
                guard let before = try snapshot(), before.safe else { return .retryLater(
                    "Remembered. Waiting for fresh awake, unlocked hardware safety checks.") }
                guard let after = try snapshot(), after.safe, before == after else { return .retryLater(
                    "Safety state changed during verification. Backlit will check again before reconnecting.") }
                guard journalsAbsent else { return .requiresRepair(
                    "Recovery ownership changed during verification. Restore your light before retrying.") }
                // Prior cleanup can remove its journal after a setter Bool
                // that proves only proxy presence. Matching native activity,
                // physical-lid and mapping caches cannot close that gap.
                return .handbackUnconfirmed
            }
            return result ?? .retryLater("Previous effects are still cleaning up. Waiting before another safety check.")
        }
    }
    private var journalsAbsent: Bool {
        ["logo-recovery.json", "fade-recovery.json", "lid-recovery.json"].allSatisfy {
            !LidWatcherStopper.journalNeedsRecovery(directory.appendingPathComponent($0))
        }
    }
}
