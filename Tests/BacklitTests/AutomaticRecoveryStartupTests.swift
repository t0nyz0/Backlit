import XCTest
@testable import Backlit

/// Exercises the model's actual startup gate and frame path, with native
/// restoration/output replaced and all durable state confined to a temp folder.
@MainActor final class AutomaticRecoveryStartupTests: XCTestCase {
    @MainActor private final class State {
        let boot = UUID()
        var now = 10.0
        var eligible = true
        var eligibilityCheck: (() -> Bool)?
        var logoJournal = true
        var lidJournal = false
        var restoreFails = false
        var removeLogoOnRestore = true
        var verifiedToken: UUID?
        var restoreTokens: [UUID] = []
        var proofTokens: [UUID] = []
        var applies = 0
        var ordinaryRestores = 0
        var ownedToken: UUID?
        var onOrdinaryRestore: (() -> Void)?
        var onRestore: (() -> Void)?
        var onProof: (() -> Void)?
        var replacementToken = UUID()
    }
    @MainActor private final class Fixture {
        let directory: URL
        let suite = "Backlit.AutomaticStartup." + UUID().uuidString
        let defaults: UserDefaults
        let intent = LidSessionIntent(duration: .init())
        let retiredToken = UUID()
        let state = State()
        let store: AutomaticRecoveryStore
        let recovery: AutomaticFadeRecovery
        let model: AppModel
        init(phase: AutomaticRecoveryStore.Phase? = .readyToResume, hardFault: Bool = false,
             logoJournal: Bool = true, lidJournal: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: suite)!
            try intent.save(defaults)
            if hardFault { _ = LidIntentController(defaults: defaults).block() }
            store = AutomaticRecoveryStore(directory: directory)
            let state = self.state, defaults = self.defaults, token = retiredToken
            state.logoJournal = logoJournal; state.lidJournal = lidJournal; state.verifiedToken = token
            if let phase {
                try store.beginAttempt(intentID: intent.id, sessionToken: token, reason: .outputTimeout,
                                       clock: .init(boot: state.boot, seconds: 1))
                if phase != .awaitingCleanup {
                    try store.markVerified(intentID: intent.id, sessionToken: token) { $0 == token }
                }
                if phase == .resumeClaimed || phase == .outputConfirmed {
                    try store.claimResume(intentID: intent.id, sessionToken: token,
                                          clock: .init(boot: state.boot, seconds: 2)) { $0 == token }
                }
                if phase == .outputConfirmed {
                    try store.markOutputConfirmed(intentID: intent.id, priorSessionToken: token, replacementToken: state.replacementToken)
                    state.verifiedToken = state.replacementToken
                }
                if phase == .cancelled { try store.cancelPending() }
            }
            let recovery = AutomaticFadeRecovery(store: store, intent: { LidSessionIntent.load(defaults) },
                clock: { .init(boot: state.boot, seconds: state.now) }, verify: { token in
                    state.proofTokens.append(token); state.onProof?()
                    return state.verifiedToken == token
                })
            self.recovery = recovery
            let environment = AutomaticRecoveryStartupEnvironment(recovery: recovery,
                eligible: { state.eligible && (state.eligibilityCheck?() ?? true) }, restore: { token in
                    state.restoreTokens.append(token); state.onRestore?()
                    if state.restoreFails { throw AutomaticRecoveryStore.Failure.unverified }
                    if state.removeLogoOnRestore { state.logoJournal = false }
                }, ownedToken: { state.ownedToken })
            model = AppModel(demo: true, defaults: defaults,
                lidStopper: LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false }),
                hardwareRestore: {
                    state.ordinaryRestores += 1; state.onOrdinaryRestore?()
                    if state.restoreFails { throw AutomaticRecoveryStore.Failure.unverified }
                    state.logoJournal = false
                },
                hardwareApply: { _, _ in
                    guard try recovery.admit() else { return .waiting }
                    state.applies += 1
                    let confirming = try recovery.store.snapshot()?.phase == .resumeClaimed
                    try recovery.outputConfirmed(token: state.replacementToken)
                    if confirming { state.ownedToken = state.replacementToken }
                    return .applied
                }, automaticRecoveryStartupEnvironment: environment,
                recoveryEnvironment: .init(hardwareAvailable: { true },
                    logoNeedsRecovery: { state.logoJournal }, lidNeedsRecovery: { state.lidJournal },
                    repairLid: { _ in XCTFail("Startup must not repair an independent lid journal") }))
        }
        func dispose() {
            state.onRestore = nil; state.onProof = nil; state.eligibilityCheck = nil; state.onOrdinaryRestore = nil
            model.controlWanted = false; model.controlling = false
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testReadyStartupRestoresExactSessionThenAppliesARealModelFrame() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.model.tick()
        XCTAssertEqual(f.state.restoreTokens, [f.retiredToken])
        XCTAssertEqual(f.state.proofTokens, [f.retiredToken])
        XCTAssertFalse(f.state.logoJournal)
        XCTAssertTrue(f.model.controlWanted); XCTAssertTrue(f.model.controlling)
        XCTAssertTrue(f.model.lightReady); XCTAssertEqual(f.state.applies, 1)
        XCTAssertEqual(f.model.agentLightState().applicationResult, "applied")
        let record = try XCTUnwrap(f.store.snapshot())
        XCTAssertEqual(record.phase, .outputConfirmed)
        XCTAssertEqual(record.replacementToken, f.state.replacementToken)
        XCTAssertEqual(record.attempts, 1)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.id, f.intent.id)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.durationSeconds, f.intent.durationSeconds)
    }

    func testAwaitingCleanupPersistsAnotherAttemptBeforeRestoreAndWaitsForBackoff() throws {
        let f = try Fixture(phase: .awaitingCleanup); defer { f.dispose() }
        f.state.onRestore = {
            XCTAssertEqual(try? f.store.snapshot()?.attempts, 2)
            XCTAssertEqual(try? f.store.snapshot()?.phase, .awaitingCleanup)
        }
        f.model.tick()
        XCTAssertEqual(f.state.restoreTokens, [f.retiredToken])
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
        XCTAssertEqual(f.state.applies, 0)
        f.state.onRestore = nil
        f.state.now = 12
        f.model.tick()
        XCTAssertEqual(f.state.applies, 1)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 2)
        XCTAssertEqual(try f.store.snapshot()?.phase, .outputConfirmed)
    }

    func testOffPowerOffAndQuitDuringRestorePersistCancellationAndNeverApply() throws {
        for withdrawal in ["off", "powerOff", "quit"] {
            let f = try Fixture(); defer { f.dispose() }
            f.state.onRestore = {
                switch withdrawal {
                case "off": f.model.setControl(false)
                case "powerOff": f.model.enabled = false
                default: XCTAssertFalse(f.model.prepareQuit())
                }
            }
            f.model.tick(); f.model.tick()
            XCTAssertFalse(f.model.controlWanted, withdrawal)
            XCTAssertFalse(f.model.controlling, withdrawal)
            XCTAssertEqual(f.state.applies, 0, withdrawal)
            let reopened = AutomaticRecoveryStore(directory: f.directory)
            XCTAssertEqual(try reopened.snapshot()?.phase, .cancelled, withdrawal)
            XCTAssertEqual(try reopened.snapshot()?.sessionToken, f.retiredToken)
            XCTAssertEqual(try reopened.snapshot()?.attempts, 1)
        }
    }

    func testOffPowerOffAndQuitDuringCompletionProofCannotAdmitAFrame() throws {
        for withdrawal in ["off", "powerOff", "quit"] {
            let f = try Fixture(); defer { f.dispose() }
            f.state.onProof = {
                if withdrawal == "off" { f.model.setControl(false) }
                else if withdrawal == "powerOff" { f.model.enabled = false }
                else { _ = f.model.prepareQuit() }
            }
            f.model.tick()
            XCTAssertEqual(f.state.applies, 0, withdrawal)
            XCTAssertFalse(f.model.controlWanted, withdrawal)
            XCTAssertEqual(try f.store.snapshot()?.phase, .cancelled, withdrawal)
        }
    }

    func testChangedIntentDuringProofCannotAdmitOldChoice() throws {
        let f = try Fixture(); defer { f.dispose() }
        let changed = LidSessionIntent(duration: .init())
        f.state.onProof = { try! changed.save(f.defaults) }
        f.model.tick()
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertFalse(f.model.controlWanted)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.id, changed.id)
        XCTAssertEqual(try f.store.snapshot()?.intentID, f.intent.id)
        XCTAssertEqual(try f.store.snapshot()?.phase, .resumeClaimed, "Consumed proof must not be replayed")
    }

    func testGenericHistoricalHardFaultIsNotAutomaticallyCleared() throws {
        for withLedger in [false, true] {
            let f = try Fixture(phase: withLedger ? .readyToResume : nil, hardFault: true); defer { f.dispose() }
            f.model.tick(); f.model.tick()
            XCTAssertTrue(f.state.restoreTokens.isEmpty)
            XCTAssertEqual(f.state.applies, 0)
            XCTAssertEqual(LidSessionIntent.load(f.defaults)?.savedPause?.reason, .hardFault)
            XCTAssertEqual(LidSessionIntent.load(f.defaults)?.blocked, true)
        }
    }

    func testChangedIntentDuringRestoreCannotClaimOldSession() throws {
        let f = try Fixture(); defer { f.dispose() }
        let changed = LidSessionIntent(duration: .init())
        f.state.onRestore = { try! changed.save(f.defaults) }
        f.model.tick(); f.model.tick()
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertFalse(f.model.controlWanted)
        XCTAssertEqual(try f.store.snapshot()?.intentID, f.intent.id)
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.id, changed.id)
    }

    func testWrongReceiptNeverClaimsStartupEvenWhenRestoreReturns() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.state.verifiedToken = UUID()
        f.model.tick(); f.model.tick()
        XCTAssertEqual(f.state.restoreTokens, [f.retiredToken])
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertFalse(f.model.controlWanted)
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
        XCTAssertTrue(f.model.needsLightRecovery)
    }

    func testIndependentLidJournalPreventsAnyAutomaticRestore() throws {
        let f = try Fixture(lidJournal: true); defer { f.dispose() }
        f.model.tick(); f.model.tick()
        XCTAssertTrue(f.state.restoreTokens.isEmpty); XCTAssertTrue(f.state.proofTokens.isEmpty)
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertTrue(f.state.lidJournal)
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
    }

    func testConfirmedOutputWithOrphanJournalCannotBecomeCleanupProof() throws {
        let f = try Fixture(phase: .outputConfirmed, logoJournal: true); defer { f.dispose() }
        f.model.tick(); f.model.tick()
        XCTAssertTrue(f.state.restoreTokens.isEmpty); XCTAssertTrue(f.state.proofTokens.isEmpty)
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertFalse(f.model.controlWanted)
        XCTAssertEqual(try f.store.snapshot()?.phase, .outputConfirmed)
        XCTAssertTrue(f.model.needsLightRecovery)
    }

    func testExpiredOrOtherwiseIneligibleCycleDoesNotRecoverOrSpendBudget() throws {
        let f = try Fixture(); defer { f.dispose() }
        f.state.eligible = false
        f.model.tick(); f.model.tick()
        XCTAssertTrue(f.state.restoreTokens.isEmpty); XCTAssertTrue(f.state.proofTokens.isEmpty)
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
        XCTAssertFalse(f.model.controlWanted)
    }

    func testExpiredOriginalTimerBlocksStartupWithoutResettingDeadline() throws {
        let f = try Fixture(); defer { f.dispose() }
        let state = f.state, intent = f.intent
        let checkpoint = LidTimerCheckpoint.closed(intent, clock: .init(boot: state.boot, seconds: 1))
        state.now = 1801
        state.eligibilityCheck = {
            if case .ready = LidIntentPolicy.timer(intent: intent, checkpoint: checkpoint,
                clock: .init(boot: state.boot, seconds: state.now), closed: true) { return true }
            return false
        }
        f.model.tick(); f.model.tick()
        XCTAssertTrue(state.restoreTokens.isEmpty); XCTAssertEqual(state.applies, 0)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
        XCTAssertEqual(checkpoint.deadline, 1801)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.id, intent.id)
    }

    func testConfirmedGracefulHandbackContinuesWithoutResettingBudget() throws {
        let f = try Fixture(phase: .outputConfirmed, logoJournal: false); defer { f.dispose() }
        let priorReplacement = f.state.replacementToken
        f.state.replacementToken = UUID() // The new process's actual owned session.
        f.model.tick()
        XCTAssertTrue(f.state.restoreTokens.isEmpty)
        XCTAssertEqual(f.state.proofTokens, [priorReplacement])
        XCTAssertEqual(f.state.applies, 1); XCTAssertTrue(f.model.lightReady)
        let record = try XCTUnwrap(f.store.snapshot())
        XCTAssertEqual(record.phase, .outputConfirmed)
        XCTAssertEqual(record.replacementToken, f.state.replacementToken)
        XCTAssertEqual(record.attempts, 1)
    }

    func testConsumedClaimFromPreviousProcessIsNotReplayed() throws {
        let f = try Fixture(phase: .resumeClaimed, logoJournal: false); defer { f.dispose() }
        f.model.tick(); f.model.tick()
        XCTAssertTrue(f.state.restoreTokens.isEmpty); XCTAssertTrue(f.state.proofTokens.isEmpty)
        XCTAssertEqual(f.state.applies, 0)
        XCTAssertFalse(f.model.controlWanted)
        XCTAssertEqual(try f.store.snapshot()?.phase, .resumeClaimed)
    }
    private func interruptedOwnedRelease() throws -> Fixture {
        let f = try Fixture(phase: nil, logoJournal: false)
        f.state.ownedToken = f.retiredToken
        f.model.controlWanted = true
        f.model.tick() // Complete the empty startup check before making a ledger.
        XCTAssertEqual(f.state.applies, 1); XCTAssertTrue(f.model.controlling)
        f.state.logoJournal = true; f.state.restoreFails = true
        f.model.setPreviewInputSession(lidClosed: false, screenAsleep: true, systemAsleep: true)
        f.model.releaseHardware()
        XCTAssertEqual(f.state.ordinaryRestores, 1)
        XCTAssertTrue(f.model.automaticRecoveryPending)
        XCTAssertEqual(try f.store.snapshot()?.phase, .awaitingCleanup)
        XCTAssertEqual(try f.store.snapshot()?.sessionToken, f.retiredToken)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
        return f
    }

    func testDirectSleepReleaseFailureAutomaticallyRecoversAfterWakeAndApplies() throws {
        let f = try interruptedOwnedRelease(); defer { f.dispose() }
        for _ in 0..<4 { f.model.tick() }
        XCTAssertEqual(f.state.ordinaryRestores, 1, "No cleanup while sleeping")
        XCTAssertEqual(f.state.applies, 1)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.blocked, false)
        f.state.restoreFails = false
        f.model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        f.model.tick()
        XCTAssertEqual(f.state.ordinaryRestores, 1, "Wake alone does not bypass backoff")
        f.state.now = 11
        f.model.tick()
        XCTAssertEqual(f.state.ordinaryRestores, 2)
        XCTAssertEqual(f.state.applies, 1, "Restore cannot also issue a stale frame")
        XCTAssertEqual(try f.store.snapshot()?.phase, .readyToResume)
        f.model.tick()
        XCTAssertEqual(f.state.applies, 2)
        XCTAssertTrue(f.model.controlWanted); XCTAssertTrue(f.model.lightReady)
        XCTAssertFalse(f.model.automaticRecoveryPending)
        XCTAssertNil(f.model.hardwareFailure)
        XCTAssertEqual(try f.store.snapshot()?.phase, .outputConfirmed)
        XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
        XCTAssertEqual(LidSessionIntent.load(f.defaults)?.id, f.intent.id)
        XCTAssertNil(LidSessionIntent.load(f.defaults)?.savedPause)
    }

    func testDirectLifecycleCleanupRetriesAreDurablyBounded() throws {
        let f = try interruptedOwnedRelease(); defer { f.dispose() }
        f.model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        for time in [11.0, 11.5, 13, 13.5, 17, 100, 1000] {
            f.state.now = time
            f.model.tick()
        }
        XCTAssertEqual(f.state.ordinaryRestores, 4, "One interrupted release plus three budgeted retries")
        XCTAssertEqual(f.state.applies, 1, "Never issue another frame after failed cleanup")
        XCTAssertEqual(try AutomaticRecoveryStore(directory: f.directory).snapshot()?.attempts, 3)
        XCTAssertFalse(f.model.controlWanted)
        XCTAssertFalse(f.model.automaticRecoveryPending)
        XCTAssertNotNil(f.model.hardwareFailure)
        XCTAssertTrue(f.state.logoJournal)
    }

    func testDirectLifecycleOffPowerOffQuitDuringRetryNeverResumeAndPersistVeto() throws {
        for withdrawal in ["off", "powerOff", "quit"] {
            let f = try interruptedOwnedRelease(); defer { f.dispose() }
            f.state.restoreFails = false
            f.state.onOrdinaryRestore = {
                if withdrawal == "off" { f.model.setControl(false) }
                else if withdrawal == "powerOff" { f.model.enabled = false }
                else { XCTAssertFalse(f.model.prepareQuit()) }
            }
            f.model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
            f.state.now = 11
            f.model.tick(); f.model.tick()
            XCTAssertEqual(f.state.applies, 1, withdrawal)
            XCTAssertFalse(f.model.controlWanted, withdrawal)
            XCTAssertEqual(try f.store.snapshot()?.phase, .cancelled, withdrawal)
            XCTAssertEqual(try f.store.snapshot()?.attempts, 1)
        }
    }

}
