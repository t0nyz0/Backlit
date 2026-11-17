import Foundation
import AppKit
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

    private func makeModel(stopper: LidWatcherStopper, hardwareRestore: (() throws -> Void)? = nil) -> AppModel {
        let suite = "local.backlit.test.lid-session." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AppModel(demo: true, defaults: defaults, lidStopper: stopper, hardwareRestore: hardwareRestore)
    }

    func testRapidOffOnRemembersLatestChoiceWithoutSkippingCleanup() async throws {
        try await checkRapidToggle(failed: false, withdraw: false)
    }
    func testRapidOffOnCannotBypassFailedCleanup() async throws {
        try await checkRapidToggle(failed: true, withdraw: false)
    }
    func testRapidOffOnOffKeepsLatestOffAfterCleanup() async throws {
        try await checkRapidToggle(failed: false, withdraw: true)
    }
    func testRapidOffOnStartsExactlyOneReplacementAfterVerifiedCleanup() async throws {
        try await checkRapidToggle(failed: false, withdraw: false, resume: true)
    }
    private func checkRapidToggle(failed: Bool, withdraw: Bool, resume: Bool = false) async throws {
        let gate = Gate(expectation(description: "toggle cleanup entered"))
        defer { gate.release() }
        let suite = "local.backlit.test.rapid-toggle." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let process = Watcher(), replacement = Watcher()
        let boot = UUID()
        var starts = 0
        weak var current: AppModel?
        let stopper = LidWatcherStopper(timeout: 2, pollInterval: 0.01,
            removeLease: { _ in if gate.calls == 0 { gate.wait() } }, needsRecovery: { _ in false })
        let environment = LidIntentEnvironment(clock: { .init(boot: boot, seconds: 100) },
            closed: { false }, safety: {
                LidResumeSafety(preview: false, enabled: true, owned: resume && current?.controlling == true, cleanupClear: current?.lifecycleAllowsFrames == true,
                    awake: true, unlocked: true, externalPower: true, battery: 0.8,
                    lowPower: false, thermal: .nominal)
            }, checkpoints: .init(directory: directory), start: { _, _ in
                XCTAssertTrue(resume); XCTAssertFalse(process.isRunning)
                XCTAssertFalse(current?.lidStopPending == true)
                starts += 1; return replacement
            })
        var restores = 0
        let model = AppModel(demo: true, defaults: defaults, lidStopper: stopper,
            hardwareRestore: { restores += 1 }, lidIntentEnvironment: environment,
            hardwareApply: { _, _ in .applied })
        current = model
        model.controlWanted = true; model.controlling = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        model.setLid(false)
        XCTAssertTrue(model.lidStopPending)
        model.setLid(true)
        XCTAssertTrue(model.lidRequested, "A rapid On must not be discarded during cleanup")
        XCTAssertNotNil(LidSessionIntent.load(defaults))
        XCTAssertFalse(model.lifecycleAllowsFrames)
        XCTAssertEqual(restores, 0); XCTAssertEqual(starts, 0)
        if withdraw { model.setLid(false) }
        let done = expectation(description: "toggle cleanup completed")
        model.onLidStopCompleted = { safe in XCTAssertEqual(safe, !failed); done.fulfill() }
        await fulfillment(of: [gate.entered], timeout: 1)
        process.terminationStatus = failed ? 6 : 0
        process.isRunning = false; gate.release()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(model.lidRequested, !withdraw)
        XCTAssertEqual(model.controlWanted, !failed)
        XCTAssertEqual(restores, failed ? 0 : 1)
        if failed { XCTAssertTrue(LidSessionIntent.load(defaults)?.blocked == true) }
        if withdraw { XCTAssertNil(LidSessionIntent.load(defaults)) }
        if resume {
            model.tick()
            XCTAssertEqual(starts, 1); XCTAssertTrue(model.keepClosed)
            model.tick(); XCTAssertEqual(starts, 1)
            let retired = expectation(description: "replacement fixture retired")
            model.onLidStopCompleted = { safe in XCTAssertTrue(safe); retired.fulfill() }
            replacement.isRunning = false
            model.setLid(false)
            await fulfillment(of: [retired], timeout: 1)
        } else if !failed {
            model.setLid(false)
            XCTAssertFalse(model.lidRequested); XCTAssertNil(LidSessionIntent.load(defaults))
        }
        model.controlling = false; model.controlWanted = false
    }

    func testExplicitLidRetryReacquiresOnlyWhenRecoveryAndPowerAllowIt() throws {
        for scenario in ["clear", "logoRecovery", "lidRecovery", "powerOff"] {
            let suite = "local.backlit.test.lid-retry." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            var saved = LidSessionIntent(duration: .init(amount: 30)); saved.blocked = true
            try saved.save(defaults)
            var applies = 0
            let environment = LidIntentEnvironment(clock: { nil }, closed: { nil }, safety: {
                LidResumeSafety(preview: true, enabled: true, owned: false, cleanupClear: true,
                    awake: true, unlocked: true, externalPower: true, battery: 0.8,
                    lowPower: false, thermal: .nominal)
            }, checkpoints: .init(directory: FileManager.default.temporaryDirectory), start: { _, _ in
                XCTFail("Preview fixture must not create a helper"); return Watcher()
            })
            let model = AppModel(demo: true, defaults: defaults,
                hardwareRestore: {}, lidIntentEnvironment: environment,
                hardwareApply: { _, _ in applies += 1; return .applied },
                recoveryEnvironment: .init(hardwareAvailable: { true },
                    logoNeedsRecovery: { scenario == "logoRecovery" },
                    lidNeedsRecovery: { scenario == "lidRecovery" }, repairLid: { _ in }))
            if scenario == "powerOff" { model.enabled = false }
            model.controlWanted = false
            model.setLid(false); model.setLid(true)
            XCTAssertEqual(model.controlWanted, scenario == "clear", scenario)
            XCTAssertEqual(applies > 0, scenario == "clear", scenario)
            XCTAssertEqual(model.enabled, scenario != "powerOff")
            model.controlling = false; model.controlWanted = false
        }
    }

    func testQuitSuppressesFramesUntilHelperAndFadeRestorationComplete() async {
        let gate = Gate(expectation(description: "quit lease removal entered"))
        defer { gate.release() }
        let process = Watcher()
        let stopper = LidWatcherStopper(timeout: 2, pollInterval: 0.01,
            removeLease: { _ in gate.wait() }, needsRecovery: { _ in false })
        var restores = 0
        weak var observedModel: AppModel?
        let model = makeModel(stopper: stopper, hardwareRestore: {
            restores += 1
            XCTAssertFalse(process.isRunning, "Fade restoration follows verified helper exit")
            guard let model = observedModel else { return XCTFail("Missing fixture model") }
            XCTAssertTrue(model.lidStopPending)
            XCTAssertTrue(model.lidCleanupInProgress)
            XCTAssertFalse(model.lifecycleAllowsFrames)
            let output = model.output
            model.tick(); model.releaseHardware(); model.setControl(true)
            XCTAssertFalse(model.prepareQuit(), "Pumped callbacks cannot approve a nested restore")
            XCTAssertEqual(model.output, output)
        })
        observedModel = model
        model.mode = .steady; model.brightness = 0.8; model.tick()
        let output = model.output
        model.controlling = true; model.controlWanted = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        let done = expectation(description: "quit continuation follows both cleanups")
        model.onLidStopCompleted = { safe in
            XCTAssertTrue(safe); XCTAssertEqual(restores, 1)
            XCTAssertFalse(model.controlling)
            XCTAssertFalse(model.lifecycleAllowsFrames, "Quit remains suspended until its continuation")
            XCTAssertTrue(model.prepareQuit())
            done.fulfill()
        }
        XCTAssertFalse(model.prepareQuit())
        model.brightness = 0.2
        for _ in 0..<100 { model.tick(); XCTAssertFalse(model.prepareQuit()) }
        XCTAssertEqual(model.output, output); XCTAssertEqual(restores, 0)
        await fulfillment(of: [gate.entered], timeout: 1)
        process.isRunning = false; gate.release()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(restores, 1); XCTAssertNil(model.error)
    }

    func testOrdinaryClosedLidDisableRetiresOldFadeBeforeResumingFrames() async {
        let gate = Gate(expectation(description: "ordinary lease removal entered"))
        defer { gate.release() }
        let process = Watcher()
        let stopper = LidWatcherStopper(timeout: 2, pollInterval: 0.01,
            removeLease: { _ in gate.wait() }, needsRecovery: { _ in false })
        var restores = 0
        let model = makeModel(stopper: stopper, hardwareRestore: {
            XCTAssertFalse(process.isRunning); restores += 1
        })
        model.mode = .steady; model.brightness = 0.8; model.tick()
        let output = model.output
        model.controlling = true; model.controlWanted = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        let done = expectation(description: "ordinary cleanup completes")
        model.onLidStopCompleted = { safe in
            XCTAssertTrue(safe); XCTAssertEqual(restores, 1)
            XCTAssertTrue(model.controlWanted, "Ordinary disable preserves requested open-lid control")
            XCTAssertFalse(model.controlling, "The next frame must acquire a fresh session")
            XCTAssertTrue(model.lifecycleAllowsFrames)
            done.fulfill()
        }
        model.stopLid(); model.brightness = 0.2
        model.tick(); model.releaseHardware()
        XCTAssertFalse(model.lifecycleAllowsFrames)
        XCTAssertEqual(model.output, output); XCTAssertEqual(restores, 0)
        await fulfillment(of: [gate.entered], timeout: 1)
        process.isRunning = false; gate.release()
        await fulfillment(of: [done], timeout: 1)
        model.tick(); XCTAssertEqual(model.output, 0.2)
        XCTAssertNil(model.error); XCTAssertTrue(model.prepareQuit())
    }

    func testVerifiedHelperExitCannotHideFadeRestoreFailureOrApproveQuit() async {
        let process = Watcher(); process.isRunning = false
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        var restores = 0
        let model = makeModel(stopper: stopper, hardwareRestore: {
            restores += 1
            throw NSError(domain: "fixture.fade", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The fade endpoint was not confirmed."])
        })
        model.controlling = true; model.controlWanted = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        let done = expectation(description: "quit rejects unconfirmed fade recovery")
        model.onLidStopCompleted = { safe in XCTAssertFalse(safe); done.fulfill() }
        XCTAssertFalse(model.prepareQuit())
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(restores, 1); XCTAssertFalse(model.controlWanted)
        XCTAssertTrue(model.controlling, "Ownership remains until restoration succeeds")
        XCTAssertEqual(model.error, "The fade endpoint was not confirmed.")
        XCTAssertFalse(model.prepareQuit()); XCTAssertEqual(restores, 2)
        // Retire only the fixture flag so teardown cannot touch real hardware.
        model.controlling = false; XCTAssertTrue(model.prepareQuit())
    }

    func testHelperFailureStopsFramesAndDoesNotAttemptFadeRestoration() async {
        let process = Watcher(); process.isRunning = false; process.terminationStatus = 6
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        var restores = 0
        let model = makeModel(stopper: stopper, hardwareRestore: { restores += 1 })
        model.controlling = true; model.controlWanted = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        let done = expectation(description: "helper failure blocks continuation")
        model.onLidStopCompleted = { safe in XCTAssertFalse(safe); done.fulfill() }
        XCTAssertFalse(model.prepareQuit())
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(restores, 0); XCTAssertFalse(model.controlWanted)
        XCTAssertFalse(model.lifecycleAllowsFrames)
        XCTAssertNotNil(model.error); XCTAssertTrue(model.controlling)
        XCTAssertTrue(model.completePowerRecovery {})
        model.controlling = false; XCTAssertTrue(model.prepareQuit())
    }

    func testSuccessfulCleanupDoesNotClearTheHardwareFailureThatTriggeredIt() async {
        let process = Watcher(); process.isRunning = false
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let model = makeModel(stopper: stopper, hardwareRestore: {})
        model.controlling = true; model.controlWanted = false
        model.error = "The original frame write failed."
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        let done = expectation(description: "failure-triggered cleanup completes")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); done.fulfill() }
        model.stopLid()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertFalse(model.controlWanted); XCTAssertFalse(model.controlling)
        XCTAssertEqual(model.error, "The original frame write failed.")
        XCTAssertTrue(model.prepareQuit())
    }

    func testCancelledQuitDoesNotRevokeLidPermissionOrRestoreHardware() {
        let process = Watcher()
        let stopper = LidWatcherStopper(removeLease: { _ in XCTFail("Cancelled quit must keep its lease") }, needsRecovery: { _ in false })
        var restores = 0
        let model = makeModel(stopper: stopper, hardwareRestore: { restores += 1 })
        model.enabled = false; model.controlWanted = true; model.controlling = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        XCTAssertFalse(model.prepareQuit(confirmOff: {
            XCTAssertFalse(model.lifecycleAllowsFrames, "Modal callbacks cannot produce frames")
            return .alertSecondButtonReturn
        }))
        XCTAssertTrue(model.lifecycleAllowsFrames); XCTAssertTrue(model.keepClosed)
        XCTAssertTrue(model.controlWanted); XCTAssertTrue(model.controlling)
        XCTAssertFalse(model.lidStopPending); XCTAssertEqual(restores, 0)
        // Retire only inert fixture ownership for teardown.
        process.isRunning = false; XCTAssertTrue(model.completePowerRecovery {})
        model.controlling = false; XCTAssertTrue(model.prepareQuit())
    }

    func testOffQuitMustRestoreSavedSettingsBeforeDroppingOwnership() {
        let stopper = LidWatcherStopper(removeLease: { _ in XCTFail("No helper exists") }, needsRecovery: { _ in false })
        var restores = 0, fail = true
        let model = makeModel(stopper: stopper, hardwareRestore: {
            restores += 1
            if fail { throw NSError(domain: "fixture.restore", code: 1) }
        })
        model.enabled = false; model.controlWanted = true; model.controlling = true
        XCTAssertFalse(model.prepareQuit(confirmOff: { .alertFirstButtonReturn }))
        XCTAssertEqual(restores, 1); XCTAssertTrue(model.controlling)
        fail = false
        XCTAssertTrue(model.prepareQuit(confirmOff: { .alertFirstButtonReturn }))
        XCTAssertEqual(restores, 2); XCTAssertFalse(model.controlling)
    }

    func testRefusedOrdinaryStopRestartsItsFrameTimerWhenNoFailureIsLatched() async throws {
        let gate = Gate(expectation(description: "existing stopper operation entered"))
        defer { gate.release() }
        let process = Watcher()
        let stopper = LidWatcherStopper(timeout: 2, pollInterval: 0.01,
            removeLease: { _ in gate.wait() }, needsRecovery: { _ in false })
        let model = makeModel(stopper: stopper)
        model.mode = .breathe
        XCTAssertTrue(model.adoptLidWatcher(process, lease: lease))
        // Exercise a refusal without setting the model's pending flag.
        XCTAssertTrue(stopper.requestStop(process: process, lease: lease,
            journal: URL(fileURLWithPath: "/tmp/isolated-model-lid-recovery")))
        model.stopLid()
        XCTAssertFalse(model.lidCleanupInProgress); XCTAssertTrue(model.lifecycleAllowsFrames)
        await fulfillment(of: [gate.entered], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000) // Drain the requested frame first.
        let initial = model.output
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(model.output, initial, "The repeating timer resumes after a refused stop")
        let done = expectation(description: "existing inert operation completes")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); done.fulfill() }
        process.isRunning = false; gate.release()
        await fulfillment(of: [done], timeout: 1)
        XCTAssertTrue(model.prepareQuit())
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
        XCTAssertFalse(model.lifecycleAllowsFrames)
        XCTAssertFalse(model.prepareQuit(), "A refused retry cannot silently resume a failed cleanup")
        XCTAssertFalse(model.lifecycleAllowsFrames)
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
