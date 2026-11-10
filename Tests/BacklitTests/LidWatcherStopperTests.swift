import Foundation
import XCTest
@testable import Backlit

/// Inert owned-process fixtures only. These tests never execute --watch-lid,
/// send an OS signal, call IOKit power APIs, or touch the live app's files.
@MainActor final class LidWatcherStopperTests: XCTestCase {
    private final class Watcher: LidWatcherProcess {
        var isRunning = true
        var terminationStatus: Int32 = 0
        var terminateCalls = 0
        var stopOnTerminate = true
        func terminate() {
            terminateCalls += 1
            if stopOnTerminate { isRunning = false }
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0
        func increment() { lock.lock(); stored += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    }
    private final class Gate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let condition = NSCondition()
        private var released = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() {
            condition.lock()
            entered.fulfill()
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }
    private let lease = URL(fileURLWithPath: "/tmp/isolated-lid-lease")
    private let journal = URL(fileURLWithPath: "/tmp/isolated-lid-recovery")

    func testCleanRemovalObservesExitWithoutSignallingOrBlocking() async throws {
        let process = Watcher(), removals = Counter()
        let stopper = LidWatcherStopper(timeout: 0.5, pollInterval: 0.01,
            removeLease: { _ in removals.increment() }, needsRecovery: { _ in false })
        let done = expectation(description: "owned fixture exits")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        XCTAssertTrue(stopper.requestStop(process: process, lease: lease, journal: journal))
        XCTAssertFalse(stopper.requestStop(process: process, lease: lease, journal: journal))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { process.isRunning = false }
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(removals.value, 1)
        XCTAssertEqual(process.terminateCalls, 0)
        XCTAssertEqual(result?.state, .stopped)
        XCTAssertTrue(try XCTUnwrap(result).safeToQuit)
        XCTAssertFalse(stopper.isStopping)
    }

    func testUnlinkFailureUsesOnlyOwnedGracefulTerminationAndReportsOrphanLease() async throws {
        let process = Watcher()
        let stopper = LidWatcherStopper(timeout: 0.5,
            removeLease: { _ in throw CocoaError(.fileWriteNoPermission) }, needsRecovery: { _ in false })
        let done = expectation(description: "graceful fixture cleanup")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        XCTAssertTrue(stopper.requestStop(process: process, lease: lease, journal: journal))
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(process.terminateCalls, 1)
        XCTAssertEqual(result?.state, .unlinkFailed)
        XCTAssertNotNil(result?.leaseRemovalError)
        XCTAssertTrue(try XCTUnwrap(result).safeToQuit, "Power restoration is confirmed even though the inert lease could not be removed")
    }

    func testExitZeroCannotHideALingeringRecoveryJournal() async {
        let process = Watcher(); process.isRunning = false
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in true })
        let done = expectation(description: "recovery retained")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        stopper.requestStop(process: process, lease: lease, journal: journal)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result?.exitStatus, 0)
        XCTAssertEqual(result?.state, .recoveryRequired)
        XCTAssertEqual(result?.recoveryRequired, true)
        XCTAssertEqual(result?.safeToQuit, false)
        XCTAssertEqual(process.terminateCalls, 0)
    }

    func testNonzeroExitRequiresRecoveryEvenWithoutAJournal() async {
        let process = Watcher(); process.isRunning = false; process.terminationStatus = 6
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let done = expectation(description: "failed fixture exit")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        stopper.requestStop(process: process, lease: lease, journal: journal)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result?.state, .recoveryRequired)
        XCTAssertEqual(result?.safeToQuit, false)
    }

    func testRunningWatcherTimesOutWithoutForceKillAndRejectsADifferentOwner() async {
        let process = Watcher()
        let stopper = LidWatcherStopper(timeout: 0.05, pollInterval: 0.01,
            removeLease: { _ in }, needsRecovery: { _ in false })
        let done = expectation(description: "bounded deadline")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        stopper.requestStop(process: process, lease: lease, journal: journal)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result?.state, .timedOut)
        XCTAssertEqual(result?.processStopped, false)
        XCTAssertNil(result?.exitStatus)
        XCTAssertEqual(result?.safeToQuit, false)
        XCTAssertEqual(process.terminateCalls, 0)
        XCTAssertFalse(stopper.requestStop(process: Watcher(), lease: lease, journal: journal))
    }

    func testBlockedUnlinkCoalescesRetriesEvenAfterDeadlineAndDropsLateCompletion() async {
        let entered = expectation(description: "filesystem fixture blocked")
        let gate = Gate(entered), calls = Counter(), process = Watcher()
        defer { gate.release() }
        let stopper = LidWatcherStopper(timeout: 0.05, pollInterval: 0.01,
            removeLease: { _ in calls.increment(); if calls.value == 1 { gate.wait() } }, needsRecovery: { _ in false })
        let timedOut = expectation(description: "main loop remains responsive")
        var outcomes: [LidWatcherStopper.Outcome] = []
        stopper.onResult = { outcomes.append($0); timedOut.fulfill() }
        stopper.requestStop(process: process, lease: lease, journal: journal)
        await fulfillment(of: [entered, timedOut], timeout: 1)
        XCTAssertEqual(outcomes.first?.state, .timedOut)
        XCTAssertTrue(stopper.hasOutstandingUnlink)
        XCTAssertTrue(stopper.hasOutstandingFilesystemWork)
        for _ in 0..<1000 { XCTAssertFalse(stopper.requestStop(process: process, lease: lease, journal: journal)) }
        XCTAssertEqual(calls.value, 1)
        process.isRunning = false
        gate.release()
        for _ in 0..<100 where stopper.hasOutstandingFilesystemWork { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(stopper.hasOutstandingFilesystemWork)
        XCTAssertEqual(outcomes.count, 1, "Late work cannot emit a stale success")
        XCTAssertEqual(process.terminateCalls, 0)
        let retry = expectation(description: "explicit retry after old work returns")
        stopper.onResult = { outcomes.append($0); retry.fulfill() }
        XCTAssertTrue(stopper.requestStop(process: process, lease: lease, journal: journal))
        await fulfillment(of: [retry], timeout: 1)
        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(outcomes.last?.state, .stopped)
    }

    func testBlockedJournalInspectionAlsoHasABoundedDeadlineAndNoRetryQueue() async {
        let entered = expectation(description: "journal fixture blocked")
        let gate = Gate(entered), process = Watcher(); process.isRunning = false
        defer { gate.release() }
        let stopper = LidWatcherStopper(timeout: 0.05,
            removeLease: { _ in }, needsRecovery: { _ in gate.wait(); return false })
        let done = expectation(description: "journal deadline")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        stopper.requestStop(process: process, lease: lease, journal: journal)
        await fulfillment(of: [entered, done], timeout: 1)
        XCTAssertEqual(result?.state, .timedOut)
        XCTAssertEqual(result?.processStopped, true)
        XCTAssertEqual(result?.safeToQuit, false)
        XCTAssertFalse(stopper.hasOutstandingUnlink)
        XCTAssertTrue(stopper.hasOutstandingFilesystemWork)
        for _ in 0..<1000 { XCTAssertFalse(stopper.requestStop(process: process, lease: lease, journal: journal)) }
        gate.release()
    }

    func testMissingLeaseIsIdempotentAndMissingHandleStillUsesGracefulStop() async {
        let process = Watcher(); process.isRunning = false
        let stopper = LidWatcherStopper(removeLease: { _ in throw CocoaError(.fileNoSuchFile) }, needsRecovery: { _ in false })
        let done = expectation(description: "already removed")
        var result: LidWatcherStopper.Outcome?
        stopper.onResult = { result = $0; done.fulfill() }
        stopper.requestStop(process: process, lease: lease, journal: journal)
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(result?.state, .stopped)
        XCTAssertEqual(result?.safeToQuit, true)
        let running = Watcher(), nilStopper = LidWatcherStopper(needsRecovery: { _ in false })
        let nilDone = expectation(description: "missing lease handle")
        nilStopper.onResult = { result = $0; nilDone.fulfill() }
        nilStopper.requestStop(process: running, lease: nil, journal: journal)
        await fulfillment(of: [nilDone], timeout: 1)
        XCTAssertEqual(running.terminateCalls, 1)
        XCTAssertEqual(result?.state, .unlinkFailed)
    }
}
