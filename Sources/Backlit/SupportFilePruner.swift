import Foundation

/// Housekeeping for files Backlit itself wrote under Application Support.
/// Nothing here reads file contents except the fade journal's token, and
/// nothing touches a recovery journal. Every failure is ignored: a leftover
/// file is harmless, a wrongly removed one is not.
enum SupportFilePruner {
    /// Agent hooks write one small file per session and remove it only on a
    /// clean session end. Events older than fifteen minutes are already
    /// ignored by the reader; remove their files once they are an hour old.
    static let agentEventMaximumAge: TimeInterval = 3600
    /// Each connect or disconnect keeps a full copy of the agent's settings,
    /// which may hold sensitive values. Keep only the most recent few.
    static let agentBackupLimit = 5

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
    private static func regularFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    @discardableResult static func pruneAgentEvents(directory: URL = AgentBridge.eventDirectory, now: Date = Date(),
                                                    maximumAge: TimeInterval = agentEventMaximumAge) -> Int {
        guard maximumAge.isFinite, maximumAge >= 900 else { return 0 }
        var removed = 0
        for file in regularFiles(in: directory) where file.pathExtension == "json" {
            // The hook rewrites its file atomically on every event, so the
            // modification date is the time of that session's last event.
            guard let date = modified(file), now.timeIntervalSince(date) > maximumAge else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    @discardableResult static func pruneAgentBackups(directory: URL = AgentBridge.directory,
                                                     keep: Int = agentBackupLimit) -> Int {
        guard keep >= 1 else { return 0 }
        let backups = regularFiles(in: directory)
            .filter { $0.lastPathComponent.hasPrefix("agent-backup-") && $0.pathExtension == "json" }
            .compactMap { file in modified(file).map { (file, $0) } }
            .sorted { $0.1 > $1.1 }
        var removed = 0
        for (file, _) in backups.dropFirst(keep) {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// A new closed-lid choice gets a new identifier, so a timer checkpoint
    /// for any other identifier can never be read again.
    @discardableResult static func pruneLidTimers(directory: URL = AgentBridge.directory, keeping current: UUID?) -> Int {
        var removed = 0
        for file in regularFiles(in: directory) {
            let name = file.lastPathComponent
            guard name.hasPrefix("lid-timer-"), file.pathExtension == "json",
                  let id = UUID(uuidString: String(name.dropFirst("lid-timer-".count).dropLast(".json".count))),
                  id != current else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// A fade session writes its journal before its lease, and only the
    /// process holding `logo.lock` may own a session. While this process holds
    /// that lock, a lease that does not belong to the journal's token is an
    /// orphan. An unreadable journal means ownership is unknown: touch nothing.
    @discardableResult static func pruneFadeLeases(directory: URL = AgentBridge.directory) -> Int {
        guard let owner = try? FileLease(url: directory.appendingPathComponent("logo.lock")) else { return 0 }
        return withExtendedLifetime(owner) {
            let journal = directory.appendingPathComponent("fade-recovery.json")
            var keep: String?
            if FileManager.default.fileExists(atPath: journal.path) {
                guard let data = try? Data(contentsOf: journal),
                      let record = try? JSONDecoder().decode(FadeRecoveryRecord.self, from: data) else { return 0 }
                keep = "fade-lease-" + record.token.uuidString
            }
            var removed = 0
            for file in regularFiles(in: directory) {
                let name = file.lastPathComponent
                guard name.hasPrefix("fade-lease-"), UUID(uuidString: String(name.dropFirst("fade-lease-".count))) != nil,
                      name != keep else { continue }
                if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
            }
            return removed
        }
    }
}
