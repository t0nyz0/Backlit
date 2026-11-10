import Foundation
import Darwin

/// One cross-process owner at a time: effect frames cannot race watchdog cleanup.
enum ClosedEffectSession {
    static func locked<T>(directory: URL = AgentBridge.directory, wait: Bool, _ body: () throws -> T) throws -> T? {
        let fd = open(directory.appendingPathComponent("closed-effect.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RuntimeServices.failure("Could not open the closed-lid effect lock.") }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw RuntimeServices.failure("Could not lock closed-lid effects.") }
            if !wait { return nil }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw RuntimeServices.failure("Closed-lid effects are still busy. Recovery was retained.") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    static func permitted(directory: URL = AgentBridge.directory) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("lid-recovery.json")),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return record["logoOverride"] as? Bool == true && record["effectsAllowed"] as? Bool == true
    }
}
