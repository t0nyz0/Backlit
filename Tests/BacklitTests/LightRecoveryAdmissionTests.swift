import XCTest
@testable import Backlit

@MainActor final class LightRecoveryAdmissionTests: XCTestCase {
    @MainActor private final class State {
        var available = true
        var logoJournal = false
        var lidJournal = false
        var removeLogoOnRestore = true
        var removeLidOnRepair = true
        var restoreFailure: Error?
        var repairFailure: Error?
        var onRestore: (() -> Void)?
        var applies = 0
        var restores = 0
        var powerRepairs: [Bool] = []
        var ambientAuthorizations = 0
    }
    @MainActor private final class Watcher: LidWatcherProcess {
        var isRunning = true
        var terminationStatus: Int32 = 0
        func terminate() { isRunning = false }
    }
    @MainActor private final class Fixture {
        let suite = "Backlit.LightRecovery." + UUID().uuidString
        let defaults: UserDefaults
        let state: State
        let model: AppModel
        init(lid: Bool = false, logo: Bool = false, stopper: LidWatcherStopper? = nil,
             observeLid: (() -> Bool)? = nil) {
            let state = State(); state.lidJournal = lid; state.logoJournal = logo
            self.state = state
            defaults = UserDefaults(suiteName: suite)!
            let environment = LightRecoveryEnvironment(hardwareAvailable: { state.available },
                logoNeedsRecovery: { state.logoJournal }, lidNeedsRecovery: { observeLid?() ?? state.lidJournal },
                repairLid: { force in
                    state.powerRepairs.append(force)
                    if let failure = state.repairFailure { throw failure }
                    if state.removeLidOnRepair { state.lidJournal = false }
                })
            model = AppModel(demo: true, defaults: defaults,
                lidStopper: stopper ?? LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false }),
                hardwareRestore: {
                    state.restores += 1; state.onRestore?()
                    if let failure = state.restoreFailure { throw failure }
                    if state.removeLogoOnRestore { state.logoJournal = false }
                }, hardwareApply: { _, _ in state.applies += 1; return .applied },
                ambientAuthorization: { _ in state.ambientAuthorizations += 1 },
                recoveryEnvironment: environment)
            model.mode = .steady
            model.automationsEnabled = true
        }
        func dispose() {
            state.onRestore = nil
            model.controlWanted = false; model.controlling = false
            defaults.removePersistentDomain(forName: suite)
        }
    }
    private func rejectExternalChanges(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try model.performAutomation(.brightness(0.2)), file: file, line: line) {
            XCTAssertEqual(($0 as? ExternalControlError)?.code, .recoveryRequired, file: file, line: line)
        }
        XCTAssertTrue(model.agentLightState().recoveryRequired, file: file, line: line)
        XCTAssertEqual(model.agentLightState().applicationResult, "recovery_required", file: file, line: line)
    }

    func testAdmissionDistinguishesAnOrphanFromRetainedOwnedLidRecovery() {
        XCTAssertFalse(LightRecoveryAdmission.unownedLidNeedsRepair(journalNeedsRecovery: false, hasOwnedWatcher: false))
        XCTAssertFalse(LightRecoveryAdmission.unownedLidNeedsRepair(journalNeedsRecovery: false, hasOwnedWatcher: true))
        XCTAssertFalse(LightRecoveryAdmission.unownedLidNeedsRepair(journalNeedsRecovery: true, hasOwnedWatcher: true))
        XCTAssertTrue(LightRecoveryAdmission.unownedLidNeedsRepair(journalNeedsRecovery: true, hasOwnedWatcher: false))
    }

    func testOrphanLidJournalBlocksStartupRearmShortcutsExternalControlsAndQuit() {
        let fixture = Fixture(lid: true); defer { fixture.dispose() }
        let model = fixture.model
        model.start()
        XCTAssertFalse(model.controlWanted)
        XCTAssertTrue(model.needsLightRecovery)
        XCTAssertTrue(model.unownedLidRecoveryRequired)
        model.setControl(true)
        model.enabled = false; model.enabled = true
        let level = model.brightness
        model.performLogoShortcut(.increase)
        model.tick(); model.announceLightReadiness()
        XCTAssertEqual(model.brightness, level)
        XCTAssertFalse(model.controlWanted)
        XCTAssertFalse(model.lightReady)
        XCTAssertNotEqual(model.notice, "Your light is ready.")
        XCTAssertEqual(fixture.state.applies, 0)
        rejectExternalChanges(model)
        XCTAssertFalse(model.prepareQuit())
        XCTAssertEqual(fixture.state.restores, 0, "Quit must not silently repair an unowned native-power session")
    }

    func testCorruptUnreadableJournalDoesNotCountAsVerifiedAbsence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("lid-recovery.json")
        try Data("not a recovery record".utf8).write(to: journal)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: journal.path)
        let fixture = Fixture(observeLid: { LidWatcherStopper.journalNeedsRecovery(journal) })
        defer { fixture.dispose() }
        fixture.model.start()
        rejectExternalChanges(fixture.model)
        XCTAssertFalse(fixture.model.restore(), "A nominal repair with an unreadable record still present is not success")
        XCTAssertEqual(fixture.state.applies, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
    }

    func testNoJournalStartsNormallyAndHealthyOwnedLogoAndLidJournalsRemainAllowed() throws {
        let fixture = Fixture(); defer { fixture.dispose() }
        let model = fixture.model
        model.start()
        XCTAssertTrue(model.controlWanted)
        XCTAssertTrue(model.lightReady)
        XCTAssertEqual(fixture.state.applies, 1)
        fixture.state.logoJournal = true; fixture.state.lidJournal = true
        let watcher = Watcher()
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/backlit-inert-owned-lease")))
        model.tick()
        XCTAssertFalse(model.unownedLidRecoveryRequired)
        XCTAssertTrue(model.lightReady)
        XCTAssertFalse(model.agentLightState().recoveryRequired)
        XCTAssertEqual(model.agentLightState().applicationResult, "applied")
        XCTAssertNoThrow(try model.performAutomation(.brightness(0.4)))
    }

    func testExplicitRestoreRearmsHardFaultWithoutReplacingTimedIntent() throws {
        let fixture = Fixture(); defer { fixture.dispose() }
        let intent = LidSessionIntent(id: UUID(), durationSeconds: 1800)!
        try intent.save(fixture.defaults)
        let controller = LidIntentController(defaults: fixture.defaults)
        XCTAssertTrue(controller.block())
        fixture.model.repairAndResume()
        XCTAssertEqual(controller.intent?.id, intent.id)
        XCTAssertEqual(controller.intent?.durationSeconds, intent.durationSeconds)
        XCTAssertEqual(controller.intent?.blocked, false)
        XCTAssertNil(controller.intent?.pause)
        XCTAssertTrue(fixture.model.controlWanted)
        XCTAssertEqual(fixture.state.applies, 1)
    }

    func testExplicitRearmRetainsOriginalDeadlineAndExpiredCycle() throws {
        let fixture = Fixture(); defer { fixture.dispose() }
        let intent = LidSessionIntent(duration: .init())
        let clock = LidContinuousClock(boot: UUID(), seconds: 100)
        let checkpoint = LidTimerCheckpoint.closed(intent, clock: clock)
        try intent.save(fixture.defaults)
        let controller = LidIntentController(defaults: fixture.defaults)
        XCTAssertTrue(controller.block())
        XCTAssertTrue(try controller.rearmAfterExplicitRestore(expectedID: intent.id))
        let retained = try XCTUnwrap(controller.intent)
        guard case let .ready(result) = LidIntentPolicy.timer(intent: retained, checkpoint: checkpoint,
            clock: .init(boot: clock.boot, seconds: 200), closed: true) else { return XCTFail("Expected original cycle") }
        XCTAssertEqual(result, checkpoint)
        guard case .expired = LidIntentPolicy.timer(intent: retained, checkpoint: checkpoint,
            clock: .init(boot: clock.boot, seconds: 1900), closed: true) else { return XCTFail("Must not earn a fresh cycle") }
    }

    func testExplicitRestoreNeverRearmsOnFailureWithdrawalOrChangedIntent() throws {
        for scenario in ["failure", "off", "quit", "changed", "legacy"] {
            let fixture = Fixture(); defer { fixture.dispose() }
            let intent = LidSessionIntent(id: UUID(), durationSeconds: 1800)!
            try intent.save(fixture.defaults)
            let controller = LidIntentController(defaults: fixture.defaults)
            XCTAssertTrue(controller.block(reason: scenario == "legacy" ? .legacyUnknown : .hardFault))
            if scenario == "failure" { fixture.state.repairFailure = RuntimeServices.failure("inert failure") }
            fixture.state.onRestore = {
                if scenario == "off" { fixture.model.setControl(false) }
                if scenario == "quit" { _ = fixture.model.prepareQuit() }
                if scenario == "changed" {
                    try! LidSessionIntent(id: UUID(), durationSeconds: 1800)!.save(fixture.defaults)
                    _ = controller.block()
                }
            }
            fixture.model.repairAndResume()
            XCTAssertEqual(controller.intent?.blocked, true, scenario)
            XCTAssertFalse(fixture.model.controlWanted, scenario)
            XCTAssertEqual(fixture.state.applies, 0, scenario)
        }
    }

    func testFailedPowerRepairAfterLogoRestorationNeverResumesAndSuccessfulRetryDoes() {
        let fixture = Fixture(lid: true, logo: true); defer { fixture.dispose() }
        let model = fixture.model
        fixture.state.repairFailure = RuntimeServices.failure("inert power restoration failed")
        model.repairAndResume()
        XCTAssertFalse(fixture.state.logoJournal, "The first stage has already succeeded")
        XCTAssertTrue(fixture.state.lidJournal, "The failed independent stage retains its recovery")
        XCTAssertFalse(model.controlWanted)
        XCTAssertFalse(model.lightReady)
        XCTAssertEqual(fixture.state.applies, 0)
        rejectExternalChanges(model)
        model.enabled = false; model.enabled = true; model.setControl(true); model.tick()
        XCTAssertEqual(fixture.state.applies, 0)
        XCTAssertFalse(model.prepareQuit())
        fixture.state.repairFailure = nil
        model.repairAndResume()
        XCTAssertFalse(fixture.state.lidJournal)
        XCTAssertTrue(model.controlWanted)
        XCTAssertTrue(model.lightReady)
        XCTAssertEqual(fixture.state.applies, 1)
        XCTAssertFalse(model.agentLightState().recoveryRequired)
    }

    func testThrownRepairWithoutRemainingJournalStillRequiresAnExplicitSuccessfulRetry() {
        let fixture = Fixture(); defer { fixture.dispose() }
        let model = fixture.model
        fixture.state.repairFailure = RuntimeServices.failure("unconfirmed native reset")
        XCTAssertFalse(model.restore())
        XCTAssertFalse(fixture.state.logoJournal)
        XCTAssertFalse(fixture.state.lidJournal)
        model.enabled = false; model.enabled = true; model.setControl(true); model.tick()
        rejectExternalChanges(model)
        XCTAssertFalse(model.prepareQuit())
        XCTAssertEqual(fixture.state.applies, 0)
        fixture.state.repairFailure = nil
        model.repairAndResume()
        XCTAssertTrue(model.lightReady)
        XCTAssertEqual(fixture.state.applies, 1)
    }

    func testSuccessfulCallbacksMustAlsoLeaveBothJournalsAbsent() {
        for retainedLid in [true, false] {
            let fixture = Fixture(lid: true, logo: true); defer { fixture.dispose() }
            fixture.state.removeLidOnRepair = !retainedLid
            fixture.state.removeLogoOnRestore = retainedLid
            fixture.model.repairAndResume()
            XCTAssertFalse(fixture.model.controlWanted)
            XCTAssertFalse(fixture.model.lightReady)
            rejectExternalChanges(fixture.model)
            XCTAssertEqual(fixture.state.applies, 0)
        }
    }

    func testFirstStageFailureDoesNotRunPowerRepairOrPermitResume() {
        let fixture = Fixture(lid: true, logo: true); defer { fixture.dispose() }
        fixture.state.restoreFailure = RuntimeServices.failure("inert source restore failed")
        fixture.model.repairAndResume()
        XCTAssertTrue(fixture.state.powerRepairs.isEmpty)
        XCTAssertTrue(fixture.state.logoJournal)
        rejectExternalChanges(fixture.model)
        XCTAssertEqual(fixture.state.applies, 0)
    }

    func testAmbientAuthorizationIsBlockedByOrphanRecoveryAndAllowedAfterSuccessfulRepair() {
        let fixture = Fixture(lid: true); defer { fixture.dispose() }
        let model = fixture.model
        model.setAmbient(true)
        XCTAssertEqual(fixture.state.ambientAuthorizations, 0, "Every native dependency is replaced; the recovery gate must reject authorization")
        XCTAssertFalse(model.ambientUnlocked)
        XCTAssertTrue(fixture.state.lidJournal)
        model.repairAndResume()
        XCTAssertTrue(model.lightReady)
        model.setAmbient(true)
        XCTAssertEqual(fixture.state.ambientAuthorizations, 1, "The same injected authorization route works once all recovery succeeds")
        XCTAssertTrue(model.ambientUnlocked)
        XCTAssertTrue(model.lightReady)
    }

    func testRetainedDeadWatcherRequiresCleanupAndExplicitRepairForcesPowerRestoration() {
        let fixture = Fixture(lid: true); defer { fixture.dispose() }
        let watcher = Watcher(); watcher.isRunning = false
        XCTAssertTrue(fixture.model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/backlit-inert-dead-lease")))
        fixture.model.controlWanted = true; fixture.model.controlling = true
        fixture.model.updateMusicHardwareReadiness { .applied }
        XCTAssertFalse(fixture.model.unownedLidRecoveryRequired, "Retain the owned handle through repair")
        XCTAssertFalse(fixture.model.lightReady)
        XCTAssertTrue(fixture.model.agentLightState().busy)
        XCTAssertEqual(fixture.model.agentLightState().applicationResult, "waiting")
        XCTAssertTrue(fixture.model.restore())
        XCTAssertEqual(fixture.state.powerRepairs, [true])
        XCTAssertFalse(fixture.model.needsLightRecovery)
    }

    func testDeadWatcherTickStartsExistingCleanupRatherThanStarvingBehindAdmissionGuard() async {
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let fixture = Fixture(lid: true, stopper: stopper); defer { fixture.dispose() }
        let model = fixture.model, watcher = Watcher()
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/backlit-inert-cleanup-lease")))
        model.controlWanted = true; model.controlling = true
        watcher.isRunning = false
        fixture.state.lidJournal = false
        let stopped = expectation(description: "existing owner cleanup completes")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); stopped.fulfill() }
        model.tick()
        XCTAssertTrue(model.lidStopPending)
        XCTAssertEqual(fixture.state.applies, 0)
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertFalse(model.lidStopPending)
        XCTAssertFalse(model.needsLightRecovery)
    }

    func testPendingCleanupRemainsBusyAndDoesNotBecomeAnOrphan() async {
        let entered = expectation(description: "inert lease removal is pending")
        let release = DispatchSemaphore(value: 0)
        let stopper = LidWatcherStopper(timeout: 2, removeLease: { _ in entered.fulfill(); release.wait() }, needsRecovery: { _ in false })
        let fixture = Fixture(lid: true, stopper: stopper)
        defer { release.signal(); fixture.dispose() }
        let model = fixture.model, watcher = Watcher()
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/backlit-inert-pending-lease")))
        model.controlWanted = true; model.controlling = true
        model.stopLid()
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(model.lidStopPending)
        XCTAssertFalse(model.unownedLidRecoveryRequired)
        XCTAssertFalse(model.lightReady)
        XCTAssertTrue(model.agentLightState().busy)
        XCTAssertFalse(model.agentLightState().recoveryRequired)
        XCTAssertFalse(model.restore())
        model.tick()
        XCTAssertEqual(fixture.state.applies, 0)
        let stopped = expectation(description: "pending cleanup is verified")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); stopped.fulfill() }
        watcher.isRunning = false; fixture.state.lidJournal = false
        release.signal()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertFalse(model.lidStopPending)
    }

    func testNewOrphanCannotRearmAfterFailedUpdate() {
        let fixture = Fixture(); defer { fixture.dispose() }
        let model = fixture.model
        XCTAssertTrue(model.prepareQuit())
        fixture.state.lidJournal = true
        model.resumeAfterUpdateFailure()
        model.tick()
        XCTAssertFalse(model.controlWanted)
        XCTAssertFalse(model.lightReady)
        rejectExternalChanges(model)
        XCTAssertEqual(fixture.state.applies, 0)
    }

    func testOffAndQuitDuringPumpedRepairWithdrawResumeIntentPermanently() {
        for withdrawal in ["controlOff", "powerOff", "quit"] {
            let fixture = Fixture(lid: true, logo: true); defer { fixture.dispose() }
            let model = fixture.model
            fixture.state.onRestore = {
                if withdrawal == "quit" { XCTAssertFalse(model.prepareQuit()) }
                else if withdrawal == "powerOff" { model.enabled = false }
                else { model.setControl(false) }
            }
            model.repairAndResume()
            model.tick(); model.tick()
            XCTAssertFalse(model.controlWanted)
            XCTAssertFalse(model.lightReady)
            XCTAssertEqual(fixture.state.applies, 0)
            XCTAssertEqual(model.enabled, withdrawal != "powerOff", "Repair must preserve the ordinary power switch's Off choice")
            XCTAssertFalse(model.needsLightRecovery, "Successful native repair is distinct from withdrawn resume intent")
        }
    }
}
