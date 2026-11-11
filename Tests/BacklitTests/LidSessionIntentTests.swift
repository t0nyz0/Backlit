import XCTest
@testable import Backlit

/// Only temporary preferences/files, fake clocks and inert process objects.
/// No live helper, power API, permission prompt or audio capture is used.
@MainActor final class LidSessionIntentTests: XCTestCase {
    private final class Watcher: LidWatcherProcess {
        var isRunning = false
        var terminationStatus: Int32 = 0
        func terminate() { isRunning = false }
    }
    @MainActor private final class Fixture {
        let suite = "local.backlit.test.intent." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backlit-intent-" + UUID().uuidString)
        lazy var defaults = UserDefaults(suiteName: suite)!
        lazy var controller = LidIntentController(defaults: defaults)
        var boot = UUID(), now = 100.0
        var closed: Bool? = true
        var preview = false, enabled = true, owned = true, cleanup = true, awake = true, unlocked = true
        var external = true, lowPower = false
        var battery: Double? = 0.8
        var thermal = ProcessInfo.ThermalState.nominal
        var starts = 0, failStart = false
        var beforeSafety: (() -> Void)?
        var process = Watcher()
        var clock: LidContinuousClock { .init(boot: boot, seconds: now) }
        var store: LidTimerCheckpointStore { .init(directory: directory) }
        var environment: LidIntentEnvironment {
            .init(clock: { self.clock }, closed: { self.closed }, safety: {
                self.beforeSafety?()
                return LidResumeSafety(preview: self.preview, enabled: self.enabled, owned: self.owned,
                    cleanupClear: self.cleanup, awake: self.awake, unlocked: self.unlocked,
                    externalPower: self.external, battery: self.battery, lowPower: self.lowPower, thermal: self.thermal)
            }, checkpoints: store, start: { intent, _ in
                self.starts += 1
                if intent.durationSeconds > 0 {
                    XCTAssertNotNil(self.store.read(intent.id), "The checkpoint is durable before helper creation")
                }
                if self.failStart { throw NSError(domain: "fixture.start", code: 1) }
                return self.process
            })
        }
        func enable(_ duration: LidSessionDuration = .init(amount: 10)) throws {
            try controller.enable(duration: duration, environment: environment)
        }
        func clean() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    }
    private func fixture() -> Fixture {
        let value = Fixture()
        addTeardownBlock { @MainActor in value.clean() }
        return value
    }

    func testSeparateInstancesPreserveChoiceDeadlineAndUnrelatedPreferencesAcrossQuitUpgrade() async throws {
        let f = fixture()
        f.defaults.set(0.37, forKey: "brightness"); f.defaults.set("keep me", forKey: "unrelated.fixture")
        try f.enable()
        let intent = try XCTUnwrap(f.controller.intent)
        _ = try f.controller.resume(environment: f.environment)
        XCTAssertEqual(f.store.read(intent.id)?.deadline, 700)
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let oldApp = AppModel(demo: true, defaults: f.defaults, lidStopper: stopper)
        XCTAssertTrue(oldApp.lidRequested); XCTAssertFalse(oldApp.keepClosed)
        XCTAssertTrue(oldApp.adoptLidWatcher(f.process, lease: f.directory.appendingPathComponent("fake-lease")))
        let stopped = expectation(description: "old version verifies cleanup")
        oldApp.onLidStopCompleted = { safe in XCTAssertTrue(safe); stopped.fulfill() }
        XCTAssertFalse(oldApp.prepareQuit())
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(oldApp.prepareQuit())
        let nextDefaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
        let nextController = LidIntentController(defaults: nextDefaults)
        let newApp = AppModel(demo: true, defaults: nextDefaults)
        XCTAssertTrue(newApp.lidRequested); XCTAssertFalse(newApp.keepClosed)
        XCTAssertFalse(newApp.canEditLidDuration)
        XCTAssertEqual(nextController.intent, intent)
        for instant in [200.0, 400, 699] {
            f.now = instant
            _ = try nextController.resume(environment: f.environment)
            XCTAssertEqual(f.store.read(intent.id)?.closedAt, 100)
            XCTAssertEqual(f.store.read(intent.id)?.deadline, 700)
        }
        f.now = 700
        let starts = f.starts
        if case .paused = try nextController.resume(environment: f.environment) {} else { XCTFail("Expired timer must remain paused") }
        XCTAssertEqual(f.starts, starts)
        XCTAssertEqual(nextDefaults.double(forKey: "brightness"), 0.37)
        XCTAssertEqual(nextDefaults.string(forKey: "unrelated.fixture"), "keep me")
        XCTAssertTrue(newApp.prepareQuit()); XCTAssertNotNil(nextController.intent)
    }

    func testMissingOldAndMalformedPreferencesNeverOptInFromDuration() throws {
        let f = fixture()
        f.defaults.set(try JSONEncoder().encode(LidSessionDuration(mode: .untilTurnedOff)), forKey: LidSessionDuration.preferenceKey)
        XCTAssertNil(f.controller.intent)
        for bytes in [Data("{}".utf8), Data("{\"version\":1,\"durationSeconds\":0}".utf8), Data([0, 255])] {
            f.defaults.set(bytes, forKey: LidSessionIntent.preferenceKey)
            XCTAssertNil(f.controller.intent)
            if case .off = try f.controller.resume(environment: f.environment) {} else { XCTFail("Malformed choice opted in") }
        }
        for (version, seconds) in [(2, 0.0), (1, -1.0), (1, 604801.0)] {
            let record: [String: Any] = ["version": version, "id": UUID().uuidString, "durationSeconds": seconds, "blocked": false]
            f.defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: LidSessionIntent.preferenceKey)
            XCTAssertNil(f.controller.intent)
        }
        XCTAssertEqual(f.starts, 0)
    }

    func testFiniteUnknownBootMissingCorruptOrMismatchedCheckpointWaitsForOpen() throws {
        let f = fixture(); try f.enable()
        let intent = try XCTUnwrap(f.controller.intent), checkpoint = try XCTUnwrap(f.store.read(intent.id))
        for value in [nil, LidTimerCheckpoint(version: 1, intent: UUID(), boot: f.boot, duration: 600, closedAt: 100, deadline: 700),
                      LidTimerCheckpoint(version: 1, intent: intent.id, boot: f.boot, duration: 600, closedAt: 100, deadline: 900)] {
            XCTAssertEqual(LidIntentPolicy.timer(intent: intent, checkpoint: value, clock: f.clock, closed: true), .needsOpen)
        }
        f.boot = UUID()
        XCTAssertEqual(LidIntentPolicy.timer(intent: intent, checkpoint: checkpoint, clock: f.clock, closed: true), .needsOpen)
        XCTAssertEqual(LidIntentPolicy.timer(intent: intent, checkpoint: checkpoint, clock: nil, closed: true), .unavailable)
        XCTAssertEqual(LidIntentPolicy.timer(intent: intent, checkpoint: checkpoint, clock: f.clock, closed: nil), .unavailable)
        if case let .ready(open?) = LidIntentPolicy.timer(intent: intent, checkpoint: checkpoint, clock: f.clock, closed: false) {
            XCTAssertNil(open.deadline); XCTAssertEqual(open.boot, f.boot)
        } else { XCTFail("A verified reopening should permit the next cycle") }
    }

    func testHelperWritesNewCycleBeforeGrantAndDoesNotRestartExpiredCycle() throws {
        let f = fixture(); f.closed = false; try f.enable()
        let intent = try XCTUnwrap(f.controller.intent)
        var checkpoint = f.store.read(intent.id), writes = 0
        let monitor = LidTimerMonitor(intent: intent, read: { checkpoint }, write: { checkpoint = $0; writes += 1 })
        XCTAssertTrue(try monitor.update(closed: false, clock: f.clock))
        f.now = 200
        XCTAssertTrue(try monitor.update(closed: true, clock: f.clock))
        XCTAssertEqual(checkpoint?.deadline, 800); XCTAssertEqual(writes, 1)
        // Continuous time includes the intervening sleep; wall time is not an input.
        f.now = 850
        XCTAssertFalse(try monitor.update(closed: true, clock: f.clock))
        XCTAssertFalse(try monitor.update(closed: true, clock: f.clock))
        XCTAssertEqual(checkpoint?.deadline, 800)
        let replacement = LidTimerMonitor(intent: intent, read: { checkpoint }, write: { checkpoint = $0 })
        XCTAssertFalse(try replacement.update(closed: true, clock: f.clock))
        XCTAssertTrue(try replacement.update(closed: false, clock: f.clock))
        f.now = 900
        XCTAssertTrue(try replacement.update(closed: true, clock: f.clock))
        XCTAssertEqual(checkpoint?.deadline, 1500)
    }

    func testCheckpointFailureCannotGrantAndClockRollbackStaysPausedUntilReopen() throws {
        let f = fixture(); f.closed = false; try f.enable()
        let intent = try XCTUnwrap(f.controller.intent)
        var checkpoint = f.store.read(intent.id), failWrite = true
        let monitor = LidTimerMonitor(intent: intent, read: { checkpoint }, write: {
            if failWrite { throw CocoaError(.fileWriteNoPermission) }
            checkpoint = $0
        })
        XCTAssertTrue(try monitor.update(closed: false, clock: f.clock))
        f.now = 200
        XCTAssertThrowsError(try monitor.update(closed: true, clock: f.clock))
        XCTAssertNil(checkpoint?.deadline)
        failWrite = false
        XCTAssertFalse(try monitor.update(closed: true, clock: f.clock), "Failed grant cannot mint another deadline while closed")
        XCTAssertTrue(try monitor.update(closed: false, clock: f.clock))
        f.now = 300; XCTAssertTrue(try monitor.update(closed: true, clock: f.clock))
        f.now = 250; XCTAssertFalse(try monitor.update(closed: true, clock: f.clock))
        f.now = 350; XCTAssertFalse(try monitor.update(closed: true, clock: f.clock))
        XCTAssertTrue(try monitor.update(closed: false, clock: f.clock))
    }

    func testOffRacingResumeWithdrawsIntentBeforeHelperCreation() throws {
        let f = fixture(); try f.enable()
        f.beforeSafety = { f.controller.disable() }
        if case .off = try f.controller.resume(environment: f.environment) {} else { XCTFail("Withdrawn intent started a helper") }
        XCTAssertEqual(f.starts, 0); XCTAssertNil(f.controller.intent)
        f.beforeSafety = nil; f.closed = false
        _ = try f.controller.resume(environment: f.environment)
        XCTAssertEqual(f.starts, 0)
    }

    func testFailureLatchSurvivesRelaunchAndOnlyExplicitOnPermitsRetry() throws {
        let f = fixture(); try f.enable(); f.failStart = true
        XCTAssertThrowsError(try f.controller.resume(environment: f.environment))
        let old = try XCTUnwrap(f.controller.intent)
        XCTAssertTrue(old.blocked)
        f.failStart = false
        let next = LidIntentController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)))
        for _ in 0..<10 { _ = try next.resume(environment: f.environment) }
        XCTAssertEqual(f.starts, 1)
        try next.enable(duration: .init(amount: 10), environment: f.environment)
        XCTAssertNotEqual(next.intent?.id, old.id)
        _ = try next.resume(environment: f.environment)
        XCTAssertEqual(f.starts, 2)
    }

    func testAllSafetyGatesBlockRememberedUnlimitedIntentWithoutErasingIt() throws {
        let f = fixture(); try f.enable(.init(mode: .untilTurnedOff))
        let checks: [(Fixture) -> Void] = [
            { $0.preview = true }, { $0.enabled = false }, { $0.owned = false }, { $0.cleanup = false },
            { $0.awake = false }, { $0.unlocked = false }, { $0.lowPower = true },
            { $0.thermal = .serious }, { $0.thermal = .critical }, { $0.battery = nil },
            { $0.external = false; $0.battery = 0.2 }
        ]
        for change in checks {
            f.preview = false; f.enabled = true; f.owned = true; f.cleanup = true; f.awake = true
            f.unlocked = true; f.lowPower = false; f.thermal = .nominal; f.battery = 0.8; f.external = true
            change(f)
            if case .paused = try f.controller.resume(environment: f.environment) {} else { XCTFail("Unsafe resume") }
            XCTAssertNotNil(f.controller.intent)
        }
        XCTAssertEqual(f.starts, 0)
    }

    func testActualModelPreparesClosedSleepingDisplayThenResumesSavedIntent() throws {
        let f = fixture(); try f.enable(); f.process.isRunning = true
        var applies = 0
        var applyResults: [FadeApplyResult] = []
        var model: AppModel!
        var environment = f.environment
        let start = environment.start
        environment.start = { intent, lease in
            XCTAssertTrue(model.controlling, "Hardware ownership must precede helper startup")
            XCTAssertEqual(applyResults, [.paused], "The initial closed-lid apply must pause before helper startup")
            return try start(intent, lease)
        }
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        model = AppModel(demo: true, defaults: f.defaults, lidStopper: stopper,
            hardwareRestore: {}, lidIntentEnvironment: environment, hardwareApply: { _, closed in
                applies += 1
                let result: FadeApplyResult = closed ? .applied : .paused
                applyResults.append(result)
                return result
            })
        defer { model = nil }
        model.mode = .steady; model.controlWanted = true; model.setPreviewLidSleep(true)
        model.tick()
        XCTAssertNil(model.pausedReason)
        XCTAssertEqual(applies, 1); XCTAssertEqual(f.starts, 1)
        XCTAssertTrue(model.controlling); XCTAssertTrue(model.keepClosed); XCTAssertTrue(model.lidRequested)
        // Finish only the inert process before model teardown.
        f.process.isRunning = false; model.controlling = false
        _ = model.prepareQuit()
    }

    func testActualModelExpiresBeforeApplyingAnotherFrameWithoutBlockingIntent() async throws {
        let f = fixture(); try f.enable(); f.process.isRunning = true
        var applies = 0, restores = 0
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let model = AppModel(demo: true, defaults: f.defaults, lidStopper: stopper,
            hardwareRestore: { restores += 1 }, lidIntentEnvironment: f.environment,
            hardwareApply: { _, _ in applies += 1; return .applied })
        model.mode = .steady; model.controlWanted = true; model.tick()
        XCTAssertEqual(applies, 1); XCTAssertTrue(model.keepClosed)
        f.now = 701
        let cleaned = expectation(description: "expired helper cleanup verified")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); cleaned.fulfill() }
        model.tick()
        XCTAssertEqual(applies, 1, "Expiry must be handled before a stale fade frame")
        XCTAssertTrue(model.lidStopPending); XCTAssertTrue(model.lidRequested)
        XCTAssertFalse(try XCTUnwrap(f.controller.intent).blocked)
        f.process.isRunning = false
        await fulfillment(of: [cleaned], timeout: 1)
        XCTAssertEqual(restores, 1); XCTAssertNil(model.error)
        XCTAssertTrue(model.controlWanted); XCTAssertTrue(model.lidRequested)
        XCTAssertTrue(model.prepareQuit())
    }

    func testPreviewNeverResumesAndSavedIntentLocksDurationUntilExplicitOff() throws {
        let f = fixture(); try f.enable()
        let model = AppModel(demo: true, defaults: f.defaults, lidIntentEnvironment: f.environment)
        model.controlWanted = true; model.controlling = true
        model.synchronizeLidIntent(force: true)
        XCTAssertEqual(f.starts, 0); XCTAssertTrue(model.lidRequested)
        let original = model.lidSessionDuration
        model.setLidDuration(amount: 9)
        XCTAssertEqual(model.lidSessionDuration, original)
        model.setLid(false)
        XCTAssertFalse(model.lidRequested); XCTAssertTrue(model.canEditLidDuration)
        XCTAssertNil(f.controller.intent)
        model.controlling = false; XCTAssertTrue(model.prepareQuit())
    }

    func testActualModelOffDuringApplyDefersCleanupButCannotResumeIntent() async throws {
        let f = fixture(); try f.enable(.init(mode: .untilTurnedOff)); f.process.isRunning = true
        var applies = 0
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let model = AppModel(demo: true, defaults: f.defaults, lidStopper: stopper,
            hardwareRestore: {}, lidIntentEnvironment: f.environment,
            hardwareApply: { _, _ in applies += 1; return .applied })
        model.mode = .steady; model.controlWanted = true; model.tick()
        XCTAssertEqual(f.starts, 1); XCTAssertTrue(model.keepClosed)
        XCTAssertTrue(model.withHardwareApply {
            model.setLid(false)
            XCTAssertNil(f.controller.intent); XCTAssertFalse(model.lidRequested)
            XCTAssertTrue(model.keepClosed, "Active batch cannot be reentered by cleanup")
        })
        let done = expectation(description: "withdrawn intent cleans up after the batch")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); done.fulfill() }
        model.tick()
        XCTAssertEqual(applies, 1, "Off is drained before another frame")
        XCTAssertTrue(model.lidStopPending); XCTAssertFalse(model.keepClosed)
        f.process.isRunning = false
        await fulfillment(of: [done], timeout: 1)
        model.synchronizeLidIntent(force: true)
        XCTAssertEqual(f.starts, 1); XCTAssertNil(f.controller.intent)
        XCTAssertFalse(model.lidRequested); XCTAssertTrue(model.prepareQuit())
    }
}
