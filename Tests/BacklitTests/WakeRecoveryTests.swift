import XCTest
@testable import Backlit

@MainActor final class WakeRecoveryTests: XCTestCase {
    func testInterruptedSleepCleanupRetriesOnlyAfterWakeAndPreservesOffPreference() {
        let suite = "Backlit.WakeRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var fail = true, restores = 0, writes = 0
        var now = 10.0
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {
            restores += 1
            if fail { throw RuntimeServices.failure("Safety state changed during restore") }
        }, hardwareApply: { level, _ in writes += 1; XCTAssertEqual(level, 0); return .applied })
        model.recoveryClock = { now }
        model.enabled = false; model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true, systemAsleep: true)
        model.releaseHardware()
        XCTAssertTrue(model.automaticRecoveryPending); XCTAssertTrue(model.controlWanted)
        XCTAssertTrue(model.controlling); XCTAssertEqual(restores, 1)
        for _ in 0..<10 { model.tick() }
        XCTAssertEqual(restores, 1); XCTAssertEqual(writes, 0)
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        model.tick()
        XCTAssertEqual(restores, 1, "Wake must respect the retry delay")
        now = 11; fail = false; model.tick()
        XCTAssertEqual(writes, 0, "The first fresh frame follows the completed recovery batch")
        model.tick()
        XCTAssertEqual(restores, 2); XCTAssertEqual(writes, 1)
        XCTAssertFalse(model.automaticRecoveryPending); XCTAssertTrue(model.controlWanted)
        XCTAssertFalse(model.enabled); XCTAssertNil(model.hardwareFailure)
        model.controlling = false
    }

    func testRepeatedRecoveryFailureIsBoundedAndNeverApplies() {
        let suite = "Backlit.WakeRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var restores = 0, now = 0.0
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {
            restores += 1; throw RuntimeServices.failure("Endpoint still unknown")
        }, hardwareApply: { _, _ in XCTFail("Unverified cleanup cannot resume effects"); return .applied })
        model.recoveryClock = { now }; model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true)
        model.releaseHardware()
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        for time in [1.0, 1.1, 2, 2.1, 4, 10, 30] { now = time; model.tick() }
        XCTAssertEqual(restores, 4, "One interrupted release plus at most three awake retries")
        XCTAssertFalse(model.automaticRecoveryPending); XCTAssertFalse(model.controlWanted)
        XCTAssertTrue(model.controlling, "Failed cleanup retains ownership and recovery")
        XCTAssertEqual(model.hardwareFailure, "Endpoint still unknown")
        model.controlling = false
    }

    func testQuitNeverTreatsPendingRecoveryAsSuccessfulCleanup() {
        let suite = "Backlit.WakeRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {
            throw RuntimeServices.failure("Cleanup has not been confirmed")
        })
        model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true)
        model.releaseHardware()
        XCTAssertTrue(model.automaticRecoveryPending)
        XCTAssertFalse(model.prepareQuit())
        XCTAssertTrue(model.controlling)
        model.controlling = false
    }
    func testExplicitControlWithdrawalCancelsPendingReconnect() {
        let suite = "Backlit.WakeRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var restores = 0
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {
            restores += 1; throw RuntimeServices.failure("Cleanup pending")
        }, hardwareApply: { _, _ in XCTFail("Withdrawn control must not resume"); return .applied })
        model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true)
        model.releaseHardware(); XCTAssertTrue(model.automaticRecoveryPending)
        model.setControl(false)
        XCTAssertFalse(model.automaticRecoveryPending); XCTAssertFalse(model.reconnecting)
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        for _ in 0..<10 { model.tick() }
        XCTAssertEqual(restores, 2, "Withdrawal tries cleanup but never schedules a restart")
        XCTAssertFalse(model.controlWanted); model.controlling = false
    }

    func testRecoveryPreservesUnrelatedErrorAndPreventsReentrantFrames() {
        let suite = "Backlit.WakeRecovery." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var fail = true, now = 0.0, writes = 0
        weak var observed: AppModel?
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {
            if fail { throw RuntimeServices.failure("Transition interrupted cleanup") }
            observed?.tick()
            XCTAssertEqual(writes, 0, "A recovery-pumped callback cannot apply")
        }, hardwareApply: { _, _ in writes += 1; return .applied })
        observed = model; model.recoveryClock = { now }
        model.controlWanted = true; model.controlling = true; model.error = "Unrelated update problem"
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true)
        model.releaseHardware()
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        now = 1; fail = false; model.tick()
        XCTAssertEqual(writes, 0)
        model.tick()
        XCTAssertEqual(writes, 1); XCTAssertEqual(model.error, "Unrelated update problem")
        model.controlling = false
    }

}
