import XCTest
@testable import Backlit

@MainActor final class AudioSessionDriverTests: XCTestCase {
    private enum FixtureError: Error { case startup }
    @MainActor private final class Suspension {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        func pause() async {
            entered = true
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true; continuation?.resume(); continuation = nil
        }
    }
    private func waitForEntry(_ gate: Suspension) async {
        for _ in 0..<200 {
            if gate.entered { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The isolated backend did not enter its suspended operation")
    }

    func testIdleStopsAndIneligibleStartsAllocateNoWorkersOrBackendCalls() async {
        var starts = 0, stops = 0
        let driver = AudioSessionDriver(start: { starts += 1 }, stop: { stops += 1 },
            eligible: { false }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
        for _ in 0..<10_000 { driver.requestStop(); driver.requestStart() }
        XCTAssertEqual(driver.workerCount, 0)
        XCTAssertEqual(starts, 0); XCTAssertEqual(stops, 0)
        XCTAssertEqual(driver.state, .idle); XCTAssertFalse(driver.hasPendingWork)
    }

    func testRepeatedRequestsCoalesceAndCompletedWorkersAreCleared() async {
        var starts = 0, stops = 0
        let driver = AudioSessionDriver(start: { starts += 1 }, stop: { stops += 1 },
            eligible: { true }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
        for cycle in 1...3 {
            for _ in 0..<10_000 { driver.requestStart() }
            await driver.waitForCurrentWork()
            XCTAssertEqual(starts, cycle); XCTAssertEqual(driver.state, .running)
            XCTAssertFalse(driver.hasPendingWork)
            for _ in 0..<10_000 { driver.requestStop() }
            await driver.waitForCurrentWork()
            XCTAssertEqual(stops, cycle); XCTAssertEqual(driver.state, .idle)
            XCTAssertFalse(driver.hasPendingWork)
            XCTAssertEqual(driver.workerCount, cycle * 2)
        }
    }

    func testPendingStartCancellationNeverPublishesRunningAndUsesOneWorker() async {
        let gate = Suspension()
        var starts = 0, stops = 0, states: [AudioSessionDriver.State] = []
        let driver = AudioSessionDriver(start: { starts += 1; await gate.pause() }, stop: { stops += 1 },
            eligible: { true }, changed: { states.append($0) }, failed: { _ in XCTFail("Unexpected error") })
        driver.requestStart(); await waitForEntry(gate)
        for _ in 0..<10_000 { driver.requestStop() }
        gate.release(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1)
        XCTAssertFalse(states.contains(.running))
        XCTAssertEqual(driver.workerCount, 1); XCTAssertFalse(driver.hasPendingWork)
    }

    func testLatestStartAfterCancelledPendingStartCleansOldSessionFirst() async {
        let gate = Suspension()
        var calls: [String] = [], starts = 0
        let driver = AudioSessionDriver(start: {
            starts += 1; calls.append("start\(starts)")
            if starts == 1 { await gate.pause() }
        }, stop: { calls.append("stop") }, eligible: { true }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
        driver.requestStart(); await waitForEntry(gate)
        driver.requestStop()
        for _ in 0..<1_000 { driver.requestStart() }
        gate.release(); await driver.waitForCurrentWork()
        XCTAssertEqual(calls, ["start1", "stop", "start2"])
        XCTAssertEqual(driver.state, .running); XCTAssertEqual(driver.workerCount, 1)
        driver.requestStop(); await driver.waitForCurrentWork()
    }

    func testEligibilityLossWhileStartingCleansUpWithoutRestarting() async {
        let gate = Suspension()
        var allowed = true, stops = 0, runningEvents = 0
        let driver = AudioSessionDriver(start: { await gate.pause() }, stop: { stops += 1 },
            eligible: { allowed }, changed: { if $0 == .running { runningEvents += 1 } }, failed: { _ in XCTFail("Unexpected error") })
        driver.requestStart(); await waitForEntry(gate)
        allowed = false; gate.release(); await driver.waitForCurrentWork()
        XCTAssertEqual(stops, 1); XCTAssertEqual(runningEvents, 0)
        XCTAssertEqual(driver.state, .idle); XCTAssertFalse(driver.hasPendingWork)
    }

    func testFailureCleansPartialSetupThenAllowsExplicitRetry() async {
        var starts = 0, stops = 0, errors = 0
        let driver = AudioSessionDriver(start: {
            starts += 1
            if starts == 1 { throw FixtureError.startup }
        }, stop: { stops += 1 }, eligible: { true }, changed: { _ in }, failed: { _ in errors += 1 })
        driver.requestStart(); await driver.waitForCurrentWork()
        XCTAssertEqual(stops, 1); XCTAssertEqual(errors, 1)
        XCTAssertEqual(driver.state, .idle); XCTAssertFalse(driver.hasPendingWork)
        driver.requestStart(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 2); XCTAssertEqual(driver.state, .running)
        driver.requestStop(); await driver.waitForCurrentWork()
    }

    func testStaleStartupFailureDoesNotCancelNewDesiredSession() async {
        let gate = Suspension()
        var starts = 0, errors = 0, stops = 0
        let driver = AudioSessionDriver(start: {
            starts += 1
            if starts == 1 { await gate.pause(); throw FixtureError.startup }
        }, stop: { stops += 1 }, eligible: { true }, changed: { _ in }, failed: { _ in errors += 1 })
        driver.requestStart(); await waitForEntry(gate)
        driver.requestStop(); driver.requestStart()
        gate.release(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 2); XCTAssertEqual(stops, 1); XCTAssertEqual(errors, 0)
        XCTAssertEqual(driver.state, .running)
        driver.requestStop(); await driver.waitForCurrentWork()
    }

    func testConsentedMusicIntentResumesAfterInterruptedQuitEvenWithUnchangedPolicy() async {
        var starts = 0, stops = 0
        let driver = AudioSessionDriver(start: { starts += 1 }, stop: { stops += 1 },
            eligible: { true }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
        driver.requestStart(); await driver.waitForCurrentWork()
        driver.retainResumeIntent(consented: true)
        driver.requestStop(); await driver.waitForCurrentWork()
        driver.resumeAfterInterruption(consented: true); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 2); XCTAssertEqual(stops, 1)
        XCTAssertEqual(driver.state, .running); XCTAssertFalse(driver.hasResumeIntent)
        driver.resumeAfterInterruption(consented: true)
        XCTAssertEqual(driver.workerCount, 3, "The interruption checkpoint is consumed exactly once")
        driver.requestStop(); await driver.waitForCurrentWork()
    }

    func testPendingConsentedStartResumesOnlyAfterCancelledSetupIsCleaned() async {
        let gate = Suspension()
        var calls: [String] = [], starts = 0
        let driver = AudioSessionDriver(start: {
            starts += 1; calls.append("start\(starts)")
            if starts == 1 { await gate.pause() }
        }, stop: { calls.append("stop") }, eligible: { true }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
        driver.requestStart(); await waitForEntry(gate)
        driver.retainResumeIntent(consented: true); driver.requestStop()
        driver.resumeAfterInterruption(consented: true)
        gate.release(); await driver.waitForCurrentWork()
        XCTAssertEqual(calls, ["start1", "stop", "start2"])
        XCTAssertEqual(driver.state, .running); XCTAssertEqual(driver.workerCount, 1)
        driver.requestStop(); await driver.waitForCurrentWork()
    }

    func testRecoveryDoesNotOverrideMissingConsentOrChangedEligibility() async {
        for retainedConsent in [false, true] {
            var starts = 0, allowed = true
            let driver = AudioSessionDriver(start: { starts += 1 }, stop: {},
                eligible: { allowed }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
            driver.requestStart(); await driver.waitForCurrentWork()
            driver.retainResumeIntent(consented: retainedConsent); driver.requestStop(); await driver.waitForCurrentWork()
            allowed = false
            driver.resumeAfterInterruption(consented: true); await driver.waitForCurrentWork()
            XCTAssertEqual(starts, 1); XCTAssertEqual(driver.state, .idle)
            allowed = true; driver.resumeAfterInterruption(consented: true)
            XCTAssertEqual(starts, 1, "A rejected checkpoint cannot silently restart later")
        }
        var starts = 0
        let driver = AudioSessionDriver(start: { starts += 1 }, stop: {}, eligible: { true }, changed: { _ in }, failed: { _ in XCTFail("Unexpected error") })
        driver.requestStart(); await driver.waitForCurrentWork()
        driver.retainResumeIntent(consented: true); driver.requestStop(); await driver.waitForCurrentWork()
        driver.resumeAfterInterruption(consented: false)
        XCTAssertEqual(starts, 1); XCTAssertFalse(driver.hasResumeIntent)
    }
}
