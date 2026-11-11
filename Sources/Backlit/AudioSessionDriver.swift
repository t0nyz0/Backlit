import Foundation

/// Serializes capture intent with one worker. Backend start/stop may suspend;
/// changes made while they do are coalesced, not queued as additional tasks.
@MainActor final class AudioSessionDriver {
    enum State: Equatable { case idle, starting, running, stopping }
    private let start: @MainActor () async throws -> Void
    private let stop: @MainActor () async -> Void
    private let eligible: () -> Bool
    private let changed: (State) -> Void
    private let failed: (Error) -> Void
    private let waitForStartupDeadline: @MainActor () async throws -> Void
    private var wanted = false
    private var running = false
    private var revision: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var startupSequence: UInt64 = 0
    private var activeStartup: UInt64?
    private var startupExpired = false
    private(set) var hasResumeIntent = false
    private(set) var state: State = .idle
    private(set) var workerCount = 0
    var hasPendingWork: Bool { worker != nil }

    init(start: @escaping @MainActor () async throws -> Void, stop: @escaping @MainActor () async -> Void,
         eligible: @escaping () -> Bool, changed: @escaping (State) -> Void,
         failed: @escaping (Error) -> Void,
         waitForStartupDeadline: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(nanoseconds: 30_000_000_000)
         }) {
        self.start = start; self.stop = stop; self.eligible = eligible
        self.changed = changed; self.failed = failed
        self.waitForStartupDeadline = waitForStartupDeadline
    }
    func requestStart() {
        // A timed-out native call still owns the backend until it returns and
        // its cleanup finishes. A retry cannot overlap or revive that attempt.
        guard !startupExpired else { return }
        guard eligible() else { requestStop(); return }
        if !wanted { wanted = true; revision &+= 1 }
        scheduleIfNeeded()
    }
    func requestStop() {
        if wanted { wanted = false; revision &+= 1 }
        if worker != nil && !running { publish(.stopping) }
        scheduleIfNeeded()
    }
    func retainResumeIntent(consented: Bool) { hasResumeIntent = wanted && consented }
    func resumeAfterInterruption(consented: Bool) {
        let resume = hasResumeIntent
        hasResumeIntent = false
        if resume && consented && eligible() { requestStart() }
    }
    func waitForCurrentWork() async { await worker?.value }
    private func publish(_ next: State) {
        guard state != next else { return }
        state = next; changed(next)
    }
    private func scheduleIfNeeded() {
        guard worker == nil, wanted != running else { return }
        workerCount += 1
        publish(wanted ? .starting : .stopping)
        worker = Task { await self.reconcile() }
    }
    private func beginStartupDeadline() {
        startupSequence &+= 1
        let sequence = startupSequence
        activeStartup = sequence
        let wait = waitForStartupDeadline
        startupDeadline = Task { [weak self] in
            do { try await wait() } catch { return }
            guard !Task.isCancelled, let self, self.activeStartup == sequence else { return }
            self.startupExpired = true
            let reportFailure = self.wanted
            self.wanted = false; self.revision &+= 1
            self.publish(.stopping)
            if reportFailure {
                self.failed(NSError(domain: "Backlit.Audio", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "macOS took too long to connect system audio."
                ]))
            }
        }
    }
    private func finishStartupDeadline() {
        activeStartup = nil
        startupDeadline?.cancel(); startupDeadline = nil
    }
    private func reconcile() async {
        while true {
            if wanted && !eligible() { wanted = false; revision &+= 1 }
            if wanted && !running {
                let attempt = revision
                publish(.starting)
                beginStartupDeadline()
                do {
                    try await start()
                    finishStartupDeadline()
                    if wanted && revision == attempt && eligible() {
                        running = true
                        publish(.running)
                    } else {
                        // A cancelled/replaced start is never published as live.
                        publish(.stopping)
                        await stop()
                    }
                } catch {
                    finishStartupDeadline()
                    // Also clean up partial setup, before permitting a retry.
                    publish(.stopping)
                    await stop()
                    if wanted && revision == attempt && eligible() {
                        wanted = false; revision &+= 1
                        failed(error)
                    }
                }
                continue
            }
            if !wanted && running {
                publish(.stopping)
                await stop()
                running = false
                continue
            }
            worker = nil
            startupExpired = false
            publish(running ? .running : .idle)
            return
        }
    }
}
