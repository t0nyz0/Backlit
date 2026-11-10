import Foundation
import Darwin

/// Only the app-created watcher is supplied here; no process lookup or group
/// termination is performed. This protocol also keeps failure fixtures inert.
@MainActor protocol LidWatcherProcess: AnyObject {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    func terminate()
}
extension Process: LidWatcherProcess {}

/// Converts SIGTERM to cooperative cancellation in the watcher child. The
/// actual signal handler is SIG_IGN; Foundation/locking runs on a GCD queue,
/// never inside an asynchronous POSIX signal handler.
final class LidWatchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var source: DispatchSourceSignal?
    private var restoreSignal: (() -> Void)?

    init() {
        let previous = signal(SIGTERM, SIG_IGN)
        restoreSignal = { _ = signal(SIGTERM, previous) }
        let next = DispatchSource.makeSignalSource(signal: SIGTERM,
            queue: DispatchQueue(label: "Backlit.LidCancellation", qos: .utility))
        next.setEventHandler { [weak self] in self?.request() }
        source = next
        next.resume()
    }
    var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
    private func request() { lock.lock(); requested = true; lock.unlock() }
    deinit { source?.cancel(); restoreSignal?() }
}

/// Bounded main-loop coordination, not a blocking wait. A stuck filesystem
/// unlink may outlive the deadline, but cannot accumulate queued retry work.
@MainActor final class LidWatcherStopper {
    struct Outcome: Equatable {
        enum State: Equatable { case stopped, unlinkFailed, timedOut, recoveryRequired }
        let state: State
        let processStopped: Bool
        let exitStatus: Int32?
        let leaseRemovalError: String?
        let recoveryRequired: Bool
        var safeToQuit: Bool { processStopped && exitStatus == 0 && !recoveryRequired }
    }
    @MainActor private final class Operation {
        let process: any LidWatcherProcess
        let lease: URL?
        let journal: URL
        var finished = false
        var removalError: String?
        var checkingJournal = false
        var journalNeedsRecovery: Bool?
        init(process: any LidWatcherProcess, lease: URL?, journal: URL) {
            self.process = process; self.lease = lease; self.journal = journal
        }
    }
    private let queue = DispatchQueue(label: "Backlit.LidLeaseCleanup", qos: .utility)
    private let removeLease: @Sendable (URL) throws -> Void
    private let needsRecovery: @Sendable (URL) -> Bool
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    private var operation: Operation?
    private(set) var isStopping = false
    private(set) var hasOutstandingUnlink = false
    private(set) var hasOutstandingFilesystemWork = false
    private(set) var lastOutcome: Outcome?
    var onResult: ((Outcome) -> Void)?

    init(timeout: TimeInterval = 3, pollInterval: TimeInterval = 0.05,
         removeLease: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
         needsRecovery: @escaping @Sendable (URL) -> Bool = { LidWatcherStopper.journalNeedsRecovery($0) }) {
        self.timeout = timeout.isFinite ? min(10, max(0.05, timeout)) : 3
        self.pollInterval = pollInterval.isFinite ? min(0.5, max(0.01, pollInterval)) : 0.05
        self.removeLease = removeLease; self.needsRecovery = needsRecovery
    }
    /// False means a request is already in flight, including a timed-out but
    /// still blocked unlink. The caller must not enqueue another continuation.
    @discardableResult func requestStop(process: any LidWatcherProcess, lease: URL?, journal: URL) -> Bool {
        guard !isStopping, !hasOutstandingFilesystemWork else { return false }
        if let old = operation, old.process !== process, old.process.isRunning { return false }
        let current = Operation(process: process, lease: lease, journal: journal)
        operation = current; isStopping = true; lastOutcome = nil
        hasOutstandingUnlink = true; hasOutstandingFilesystemWork = true
        let remove = removeLease
        queue.async { [weak self] in
            let removalError: String?
            if let lease {
                do { try remove(lease); removalError = nil }
                catch where Self.isMissing(error) { removalError = nil }
                catch { removalError = error.localizedDescription }
            } else {
                removalError = "The closed-lid session lease is unavailable."
            }
            DispatchQueue.main.async { [weak self] in
                self?.removedLease(for: current, error: removalError)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.operation === current, !current.finished else { return }
            self.finish(current, timedOut: true)
        }
        return true
    }
    private func removedLease(for current: Operation, error: String?) {
        guard operation === current else { return }
        hasOutstandingUnlink = false; hasOutstandingFilesystemWork = false
        // A timed-out operation cannot signal a later watcher or emit another
        // result. Retained handles allow an explicit retry after this point.
        guard !current.finished else { return }
        current.removalError = error
        if error != nil && current.process.isRunning { current.process.terminate() }
        observe(current)
    }
    private func observe(_ current: Operation) {
        guard operation === current, !current.finished else { return }
        if !current.process.isRunning {
            guard !current.checkingJournal else { return }
            current.checkingJournal = true; hasOutstandingFilesystemWork = true
            let inspect = needsRecovery, journal = current.journal
            queue.async { [weak self] in
                let needsRecovery = inspect(journal)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operation === current else { return }
                    self.hasOutstandingFilesystemWork = false
                    guard !current.finished else { return }
                    current.journalNeedsRecovery = needsRecovery
                    self.finish(current, timedOut: false)
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { [weak self] in self?.observe(current) }
    }
    private func finish(_ current: Operation, timedOut: Bool) {
        guard operation === current, !current.finished else { return }
        current.finished = true; isStopping = false
        let stopped = !current.process.isRunning
        let status = stopped ? current.process.terminationStatus : nil
        let recovery = (current.journalNeedsRecovery ?? true) || (stopped && status != 0)
        let state: Outcome.State = timedOut ? .timedOut : recovery ? .recoveryRequired : current.removalError != nil ? .unlinkFailed : .stopped
        let outcome = Outcome(state: state, processStopped: stopped, exitStatus: status,
                              leaseRemovalError: current.removalError, recoveryRequired: recovery)
        lastOutcome = outcome
        // Failed/pending operations keep their handles. A clean exit with an
        // orphan lease is safe for power, but its cleanup error remains visible.
        if outcome.safeToQuit && current.removalError == nil { operation = nil }
        onResult?(outcome)
    }
    nonisolated private static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code) ||
            value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)
    }
    nonisolated static func journalNeedsRecovery(_ url: URL) -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
        catch { return !isMissing(error) } // Unreadable is not proof of restoration.
    }
}
