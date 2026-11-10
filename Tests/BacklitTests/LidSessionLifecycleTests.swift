import Foundation
import XCTest
@testable import Backlit

/// AppModel wiring with inert helpers and injected filesystem closures only.
/// No watcher process, power repair, live settings, or hardware is used.
@MainActor final class LidSessionLifecycleTests: XCTestCase {
    private final class Watcher: LidWatcherProcess {
        var isRunning = true
        var terminationStatus: Int32 = 0
        var terminateCalls = 0
        func terminate() { terminateCalls += 1; isRunning = false }
    }
    private final class Gate: @unchecked Sendable {
        private let condition = NSCondition()
        private var released = false
        private var storedCalls = 0
        let entered: XCTestExpectation
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() {
            condition.lock()
            storedCalls += 1; entered.fulfill()
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
        var calls: Int { condition.lock(); defer { condition.unlock() }; return storedCalls }
    }
    private let lease = URL(fileURLWithPath: "/tmp/isolated-model-lid-lease")

    private func makeModel(stopper: LidWatcherStopper) -> AppModel {
        let suite = "local.backlit.test.lid-session." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(demo: true, defaults: defaults, lidStopper: stopper)
    }

    func testQuitCoalescesCleanupAndLeavesMainLoopResponsive() async throws {
        let gate = Gate(expectation(description: "inert lease removal entered"))
        defer { gate.release() }
        let stopper = LidWatcherStopper(timeout: 2, pollInterval: 0.01,
            removeLease: { _ in gate.wait() }, needsRecovery: { _ in false })
        let model = makeModel(stopper: stopper), process = Watcher()
        let done = expectation(description: "model reports verified cleanup")
        var outcomes: [Bool] = []
        model.onLidStopCompleted = { outcomes.append($0); done.fulfill() }
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        XCTAssertFalse(model.completePowerRecovery { XCTFail("Cannot repair a running helper") })
        XCTAssertFalse(model.prepareQuit())
        XCTAssertTrue(model.lidStopPending)
        for _ in 0..<100 { XCTAssertFalse(model.prepareQuit()) }
        XCTAssertFalse(model.adoptLidWatcher(Watcher(), lease: lease))
        XCTAssertFalse(model.completePowerRecovery { XCTFail("Cannot repair during cleanup") })
        let responsive = expectation(description: "main loop is free during unlink")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [gate.entered, responsive], timeout: 1)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertTrue(model.lidStopPending)
        process.isRunning = false
        gate.release()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(outcomes, [true])
        XCTAssertFalse(model.lidStopPending)
        XCTAssertEqual(process.terminateCalls, 0)
        XCTAssertTrue(model.prepareQuit())
    }

    func testFailedExitRetainsOwnershipUntilExplicitRepairSucceeds() async throws {
        let stopper = LidWatcherStopper(timeout: 1, pollInterval: 0.01,
            removeLease: { _ in }, needsRecovery: { _ in false })
        let model = makeModel(stopper: stopper), failed = Watcher()
        failed.isRunning = false; failed.terminationStatus = 6
        let failedCleanup = expectation(description: "model preserves recovery failure")
        var outcomes: [Bool] = []
        model.onLidStopCompleted = { outcomes.append($0); failedCleanup.fulfill() }
        XCTAssertTrue(model.adoptLidWatcher(failed, lease: lease))
        XCTAssertFalse(model.prepareQuit())
        await fulfillment(of: [failedCleanup], timeout: 1)
        XCTAssertEqual(outcomes, [false])
        XCTAssertEqual(stopper.lastOutcome?.exitStatus, 6)
        XCTAssertFalse(model.lidStopPending)
        XCTAssertFalse(model.adoptLidWatcher(Watcher(), lease: lease))
        var repairs = 0
        XCTAssertThrowsError(try model.completePowerRecovery {
            repairs += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(repairs, 1)
        XCTAssertFalse(model.adoptLidWatcher(Watcher(), lease: lease), "A failed repair cannot discard the old owner")
        XCTAssertTrue(model.completePowerRecovery { repairs += 1 })
        XCTAssertEqual(repairs, 2)
        let next = Watcher(); next.isRunning = false
        XCTAssertTrue(model.adoptLidWatcher(next, lease: lease), "Verified repair permits a new owned session")
        let clean = expectation(description: "replacement session cleans up")
        model.onLidStopCompleted = { outcomes.append($0); clean.fulfill() }
        XCTAssertFalse(model.prepareQuit())
        await fulfillment(of: [clean], timeout: 1)
        XCTAssertEqual(outcomes, [false, true])
        XCTAssertTrue(model.prepareQuit())
    }

    func testTimedOutFilesystemWorkCannotBeClearedByRepair() async throws {
        let gate = Gate(expectation(description: "inert unlink blocked"))
        defer { gate.release() }
        let stopper = LidWatcherStopper(timeout: 0.05, pollInterval: 0.01,
            removeLease: { _ in gate.wait() }, needsRecovery: { _ in false })
        let model = makeModel(stopper: stopper), process = Watcher()
        process.isRunning = false
        let timedOut = expectation(description: "model receives bounded cleanup failure")
        var outcomes: [Bool] = []
        model.onLidStopCompleted = { outcomes.append($0); timedOut.fulfill() }
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        XCTAssertFalse(model.prepareQuit())
        await fulfillment(of: [gate.entered, timedOut], timeout: 1)
        XCTAssertEqual(outcomes, [false])
        XCTAssertFalse(model.lidStopPending)
        XCTAssertTrue(stopper.hasOutstandingFilesystemWork)
        XCTAssertFalse(model.completePowerRecovery { XCTFail("A timed-out unlink still owns its filesystem work") })
        XCTAssertFalse(model.adoptLidWatcher(Watcher(), lease: lease))
        gate.release()
        for _ in 0..<100 where stopper.hasOutstandingFilesystemWork {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(stopper.hasOutstandingFilesystemWork)
        XCTAssertEqual(outcomes, [false], "Late unlink completion cannot silently approve quit")
        XCTAssertTrue(model.completePowerRecovery {})
        XCTAssertTrue(model.prepareQuit())
    }
}
