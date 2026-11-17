import XCTest
@testable import Backlit

@MainActor final class StatusInvalidationTests: XCTestCase {
    @MainActor private final class RecoveryState { var lidJournal = false; var writes = 0 }
    private final class FailedWatcher: LidWatcherProcess {
        var isRunning: Bool { false }
        var terminationStatus: Int32 { 6 }
        func terminate() { XCTFail("The inert watcher is already stopped") }
    }
    @MainActor private final class Fixture {
        let suite = "Backlit.StatusInvalidation." + UUID().uuidString
        let store: UserDefaults
        let state = RecoveryState()
        let model: AppModel
        init(stopper: LidWatcherStopper? = nil) {
            store = UserDefaults(suiteName: suite)!
            store.set(GlowMode.steady.rawValue, forKey: "mode")
            store.set(0.65, forKey: "brightness")
            let state = self.state
            model = AppModel(demo: true, defaults: store, lidStopper: stopper,
                hardwareRestore: {}, hardwareApply: { _, _ in state.writes += 1; return .applied },
                recoveryEnvironment: .init(hardwareAvailable: { true }, logoNeedsRecovery: { false },
                    lidNeedsRecovery: { state.lidJournal }, repairLid: { _ in state.lidJournal = false }))
            model.controlWanted = true
        }
        func dispose() {
            model.onIconChange = nil; model.onLidStopCompleted = nil
            model.controlling = false; model.controlWanted = false
            _ = model.completePowerRecovery {}
            store.removePersistentDomain(forName: suite)
        }
    }
    func testNewOrphanRecoveryInvalidatesTheNativePresentationOnTheEarlyReturn() {
        let fixture = Fixture(); defer { fixture.dispose() }
        let model = fixture.model
        model.tick()
        XCTAssertTrue(model.lightReady)
        let priorWrites = fixture.state.writes
        var invalidations = 0, recovery = false
        model.onIconChange = { [weak model] in
            invalidations += 1; recovery = model?.needsLightRecovery == true
        }
        fixture.state.lidJournal = true
        model.tick()
        XCTAssertEqual(invalidations, 1, "Recovery must invalidate the native presentation even when no frame is allowed")
        XCTAssertTrue(recovery)
        XCTAssertEqual(fixture.state.writes, priorWrites)
        XCTAssertFalse(model.controlWanted)
    }
    func testFailedAsyncLidCleanupDoesNotLeaveTheLastNativePresentationCached() async {
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in true })
        let fixture = Fixture(stopper: stopper); defer { fixture.dispose() }
        let model = fixture.model
        model.tick()
        XCTAssertTrue(model.adoptLidWatcher(FailedWatcher(), lease: URL(fileURLWithPath: "/tmp/backlit-inert-status-lease")))
        let finished = expectation(description: "inert failed helper cleanup")
        model.onLidStopCompleted = { safe in XCTAssertFalse(safe); finished.fulfill() }
        model.stopLid()
        await fulfillment(of: [finished], timeout: 1)
        var invalidations = 0, recovery = false
        model.onIconChange = { [weak model] in
            invalidations += 1; recovery = model?.needsLightRecovery == true
        }
        let priorWrites = fixture.state.writes
        model.tick()
        XCTAssertEqual(invalidations, 1, "A failed cleanup gate must refresh the menu presentation")
        XCTAssertTrue(recovery)
        XCTAssertEqual(fixture.state.writes, priorWrites)
        XCTAssertFalse(model.controlWanted)
    }
    func testBusyEarlyReturnInvalidatesWithoutReenteringHardware() {
        let fixture = Fixture(); defer { fixture.dispose() }
        let model = fixture.model
        var invalidations = 0, busy = false
        model.onIconChange = { [weak model] in
            invalidations += 1; busy = model?.hardwareOperationInProgress == true
        }
        XCTAssertTrue(model.withHardwareApply { model.tick() })
        XCTAssertEqual(invalidations, 1)
        XCTAssertTrue(busy)
        XCTAssertEqual(fixture.state.writes, 0)
    }
    func testOrdinaryFrameInvalidatesExactlyOnce() {
        let fixture = Fixture(); defer { fixture.dispose() }
        var invalidations = 0
        fixture.model.onIconChange = { invalidations += 1 }
        fixture.model.tick()
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(fixture.state.writes, 1)
    }
}
