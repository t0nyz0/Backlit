import XCTest
@testable import Backlit

/// Real isolated preference migration, filesystem journals and process locks.
/// Native snapshots and process handles are inert; no live API writes occur.
/// Positive admission tests explicitly simulate qualified handback in a
/// preview-only fixture. They do not qualify the native snapshot inspector.
@MainActor final class LidSavedPauseRecoveryTests: XCTestCase {
    private final class Watcher: LidWatcherProcess {
        var isRunning = true
        var terminationStatus: Int32 = 0
        func terminate() { isRunning = false }
    }
    @MainActor private final class Fixture {
        let suite = "Backlit.SavedPause." + UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("backlit-pause-" + UUID().uuidString)
        lazy var defaults = UserDefaults(suiteName: suite)!
        lazy var controller = LidIntentController(defaults: defaults)
        var boot = UUID(), now = 100.0
        var eligible = true, closed: Bool? = true
        var reads = 0, checks = 0, starts = 0
        var onSnapshot: (() -> Void)?
        var snapshot = LidPauseRecoveryVerifier.Snapshot(
            context: .init(lidClosed: true, sleeping: false, locked: false, generation: 1),
            keyboards: [1: 1], mapping: [[0, 1], [1000, 1000]])
        let watcher = Watcher()
        var clock: LidContinuousClock { .init(boot: boot, seconds: now) }
        var store: LidTimerCheckpointStore { .init(directory: directory) }
        var verifier: LidPauseRecoveryVerifier {
            .init(directory: directory, snapshot: {
                self.reads += 1; self.onSnapshot?(); return self.snapshot
            })
        }
        var recovery: LidPauseRecoveryEnvironment {
            .init(clock: { self.clock }, eligible: { self.eligible }, verify: {
                self.checks += 1; return try self.qualifiedFixtureVerification()
            }, allowsAutomaticClearance: true)
        }
        func qualifiedFixtureVerification() throws -> LidPauseVerification {
            let preflight = try verifier.verify()
            // Synthetic qualification is supplied only by this fixture.
            // Production has no equivalent provider or permission gate.
            if case .handbackUnconfirmed = preflight { return .verified }
            return preflight
        }
        var session: LidIntentEnvironment {
            .init(clock: { self.clock }, closed: { self.closed }, safety: {
                .init(preview: false, enabled: true, owned: true, cleanupClear: true,
                      awake: self.eligible, unlocked: self.eligible, externalPower: true,
                      battery: 0.8, lowPower: false, thermal: .nominal)
            }, checkpoints: store, start: { _, _ in self.starts += 1; return self.watcher })
        }
        func legacy(duration: Double = 0) throws -> UUID {
            let id = UUID()
            let record: [String: Any] = ["version": 1, "id": id.uuidString, "durationSeconds": duration, "blocked": true]
            defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: LidSessionIntent.preferenceKey)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return id
        }
        func clean() {
            watcher.isRunning = false
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }
    private func fixture() -> Fixture {
        let value = Fixture()
        addTeardownBlock { @MainActor in value.clean() }
        return value
    }

    func testProductionGateCannotBeEnabledByInjectedFixtureQualification() {
        let f = fixture()
        XCTAssertTrue(f.recovery.available(inPreview: true))
        XCTAssertFalse(f.recovery.available(inPreview: false))
        var unqualified = f.recovery
        unqualified.allowsAutomaticClearance = false
        XCTAssertFalse(unqualified.available(inPreview: true))
        XCTAssertFalse(unqualified.available(inPreview: false))
    }

    func testStableSnapshotsAndAbsentJournalsDoNotConfirmNativeHandback() throws {
        let f = fixture(); _ = try f.legacy()
        let original = f.defaults.data(forKey: LidSessionIntent.preferenceKey)
        for _ in 0..<3 {
            guard case .handbackUnconfirmed = try f.verifier.verify() else {
                return XCTFail("Native activity and physical-lid caches cannot qualify handback")
            }
        }
        XCTAssertEqual(f.reads, 6)
        XCTAssertEqual(f.defaults.data(forKey: LidSessionIntent.preferenceKey), original)
        XCTAssertEqual(f.starts, 0)
    }

    func testUnqualifiedRelaunchRetainsLegacyAndInterruptedChoiceDeadlineAndRetryHistory() throws {
        for reason: LidSavedPause.Reason in [.legacyUnknown, .interruptedCleanup] {
            for attempts in [0, 2, 3] {
                let f = fixture(), id = try f.legacy(duration: 600)
                var intent = try XCTUnwrap(f.controller.intent)
                if reason != .legacyUnknown || attempts != 0 {
                    intent.pause = .init(reason: reason, attempts: attempts,
                        retryBoot: attempts > 0 ? f.boot : nil, retryAfter: attempts > 0 ? 102 : nil)
                    try intent.save(f.defaults)
                }
                try f.store.write(.init(version: 1, intent: id, boot: f.boot,
                                       duration: 600, closedAt: 100, deadline: 700))
                let original = f.defaults.data(forKey: LidSessionIntent.preferenceKey)
                let checkpoint = try Data(contentsOf: f.store.url(id))
                let environment = LidPauseRecoveryEnvironment(clock: {
                    XCTFail("An unqualified production path must not even poll its recovery clock")
                    return f.clock
                }, eligible: {
                    XCTFail("Unqualified recovery must not read cached native safety state")
                    return true
                }, verify: {
                    XCTFail("No native handback provider is qualified")
                    return .verified
                })
                for _ in 0..<4 {
                    f.now += 1_000; f.boot = UUID()
                    let relaunched = LidIntentController(defaults: UserDefaults(suiteName: f.suite)!)
                    XCTAssertFalse(try relaunched.recoverSavedPause(environment: environment))
                    _ = try relaunched.resume(environment: f.session)
                    XCTAssertEqual(f.defaults.data(forKey: LidSessionIntent.preferenceKey), original)
                    XCTAssertEqual(try Data(contentsOf: f.store.url(id)), checkpoint)
                    XCTAssertEqual(relaunched.intent?.id, id)
                    XCTAssertEqual(relaunched.intent?.durationSeconds, 600)
                    XCTAssertTrue(relaunched.intent!.savedPause!.status.contains("Recovery unconfirmed"))
                }
                XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.checks, 0); XCTAssertEqual(f.reads, 0)
            }
        }
    }

    func testUnconfirmedInspectorDoesNotSpendOrResetRetainedAttemptBudget() throws {
        let f = fixture(); _ = try f.legacy()
        var intent = try XCTUnwrap(f.controller.intent)
        intent.pause = .init(reason: .interruptedCleanup, attempts: 1,
                             retryBoot: f.boot, retryAfter: 99)
        try intent.save(f.defaults)
        var environment = f.recovery
        environment.verify = { try f.verifier.verify() } // No synthetic qualification.
        for _ in 0..<3 {
            XCTAssertFalse(try f.controller.recoverSavedPause(environment: environment))
            XCTAssertEqual(f.controller.intent, intent)
        }
        XCTAssertEqual(f.starts, 0)
    }

    func testActualModelWithoutQualifiedProviderRemainsPausedWithoutRetryLoop() throws {
        for reason: LidSavedPause.Reason in [.legacyUnknown, .interruptedCleanup] {
            let f = fixture(), id = try f.legacy(duration: 600)
            if reason == .interruptedCleanup {
                var intent = try XCTUnwrap(f.controller.intent)
                intent.pause = .init(reason: reason, attempts: 2, retryBoot: f.boot, retryAfter: 102)
                try intent.save(f.defaults)
            }
            try f.store.write(.init(version: 1, intent: id, boot: f.boot,
                                   duration: 600, closedAt: 100, deadline: 700))
            let original = f.defaults.data(forKey: LidSessionIntent.preferenceKey)
            let checkpoint = try Data(contentsOf: f.store.url(id))
            let environment = LidPauseRecoveryEnvironment(clock: {
                XCTFail("The production-default recovery path must not poll its clock"); return f.clock
            }, eligible: {
                XCTFail("The production-default recovery path must stay disabled"); return true
            }, verify: {
                XCTFail("Empty journals cannot authorize a verification attempt"); return .verified
            })
            for _ in 0..<3 {
                let recreatedDefaults = UserDefaults(suiteName: f.suite)!
                let model = AppModel(demo: true, defaults: recreatedDefaults, hardwareRestore: {},
                    lidIntentEnvironment: f.session,
                    hardwareApply: { _, _ in XCTFail("Unconfirmed saved recovery cannot start effects"); return .applied },
                    lidPauseRecoveryEnvironment: environment)
                model.controlWanted = true
                for _ in 0..<10 { f.now += 10; model.tick() }
                XCTAssertEqual(recreatedDefaults.data(forKey: LidSessionIntent.preferenceKey), original)
                XCTAssertEqual(try Data(contentsOf: f.store.url(id)), checkpoint)
                XCTAssertEqual(LidIntentController(defaults: recreatedDefaults).intent?.id, id)
                XCTAssertEqual(model.lidPreferenceStatus, LidSavedPause.unconfirmedStatus)
                XCTAssertEqual(model.status, LidSavedPause.unconfirmedStatus)
                XCTAssertTrue(model.savedLidPauseNeedsReview); XCTAssertEqual(f.starts, 0)
            }
        }
    }

    func testQualifiedFixturePreservesUnlimitedChoiceWhenAdmitted() throws {
        let f = fixture(), id = try f.legacy()
        f.defaults.set(0.42, forKey: "brightness")
        // Leftover files are not held ownership and must not force manual work.
        try Data().write(to: f.directory.appendingPathComponent("fade-lease-" + UUID().uuidString))
        XCTAssertEqual(f.controller.intent?.savedPause?.reason, .legacyUnknown)
        XCTAssertTrue(try f.controller.recoverSavedPause(environment: f.recovery))
        XCTAssertEqual(f.reads, 2); XCTAssertEqual(f.controller.intent?.id, id)
        XCTAssertEqual(f.controller.intent?.durationSeconds, 0)
        XCTAssertFalse(try XCTUnwrap(f.controller.intent).blocked)
        XCTAssertEqual(f.defaults.double(forKey: "brightness"), 0.42)
        _ = try f.controller.resume(environment: f.session)
        XCTAssertEqual(f.starts, 1)
    }

    func testTimedRecoveryPreservesExactCheckpointAndExpiredDeadline() throws {
        for now in [300.0, 700, 900] {
            let f = fixture(), id = try f.legacy(duration: 600)
            let checkpoint = LidTimerCheckpoint(version: 1, intent: id, boot: f.boot,
                duration: 600, closedAt: 100, deadline: 700)
            try f.store.write(checkpoint)
            let bytes = try Data(contentsOf: f.store.url(id))
            f.now = now
            XCTAssertTrue(try f.controller.recoverSavedPause(environment: f.recovery))
            _ = try f.controller.resume(environment: f.session)
            XCTAssertEqual(try Data(contentsOf: f.store.url(id)), bytes)
            XCTAssertEqual(f.starts, now < 700 ? 1 : 0)
            XCTAssertEqual(f.controller.intent?.id, id)
        }
    }

    func testMissingCorruptOrForeignTimedCheckpointCannotStartAfterLegacyVerification() throws {
        for bytes in [Data(), Data("bad json".utf8), try JSONEncoder().encode(LidTimerCheckpoint(
            version: 1, intent: UUID(), boot: UUID(), duration: 600, closedAt: 100, deadline: 700))] {
            let f = fixture(), id = try f.legacy(duration: 600)
            try bytes.write(to: f.store.url(id))
            XCTAssertTrue(try f.controller.recoverSavedPause(environment: f.recovery))
            _ = try f.controller.resume(environment: f.session)
            XCTAssertEqual(f.starts, 0)
            XCTAssertEqual(try Data(contentsOf: f.store.url(id)), bytes)
        }
    }

    func testEveryResidualOrCorruptJournalRequiresRepairAndIsLeftUntouched() throws {
        for name in ["logo-recovery.json", "fade-recovery.json", "lid-recovery.json"] {
            for data in [Data("corrupt".utf8), Data("{}".utf8)] {
                let f = fixture(); _ = try f.legacy()
                let url = f.directory.appendingPathComponent(name)
                try data.write(to: url)
                XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
                XCTAssertEqual(f.controller.intent?.pause?.reason, .hardFault)
                XCTAssertEqual(try Data(contentsOf: url), data)
                XCTAssertEqual(f.reads, 0)
                let next = LidIntentController(defaults: f.defaults)
                XCTAssertFalse(try next.recoverSavedPause(environment: f.recovery))
                XCTAssertEqual(f.checks, 1)
                XCTAssertTrue(next.intent!.savedPause!.status.contains("Restore Light"))
            }
        }
    }

    func testForeignHeldOwnerAndCapabilityDenialNeverClearOrStart() throws {
        let f = fixture(); _ = try f.legacy()
        let owner = try FileLease(url: f.directory.appendingPathComponent("logo.lock"))
        try withExtendedLifetime(owner) {
            XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
        }
        XCTAssertEqual(f.controller.intent?.pause?.reason, .hardFault)
        XCTAssertEqual(f.reads, 0); XCTAssertEqual(f.starts, 0)
        let g = fixture(); _ = try g.legacy()
        var denied = g.recovery
        denied.verify = { throw CocoaError(.fileReadNoPermission) }
        XCTAssertFalse(try g.controller.recoverSavedPause(environment: denied))
        XCTAssertEqual(g.controller.intent?.pause?.reason, .hardFault)
        XCTAssertFalse(try g.controller.recoverSavedPause(environment: g.recovery))
        XCTAssertEqual(g.checks, 0)
    }

    func testValidForeignFadeJournalAndReceiptCannotAuthorizeUnknownLegacyOwner() throws {
        let f = fixture(); _ = try f.legacy()
        let store = FadeRecoveryStore(directory: f.directory)
        let token = try store.prepare(parentPID: 12345, context: f.snapshot.context, keyboards: f.snapshot.keyboards)
        let journal = try Data(contentsOf: store.url)
        try store.recover(token: token) { _ in } // Unused fixture session; no hardware exists.
        XCTAssertTrue(store.completed(token: token))
        try journal.write(to: store.url) // Model a stale journal left beside a receipt.
        XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
        XCTAssertEqual(f.controller.intent?.pause?.reason, .hardFault)
        XCTAssertEqual(try Data(contentsOf: store.url), journal)
        XCTAssertTrue(store.completed(token: token)); XCTAssertEqual(f.reads, 0); XCTAssertEqual(f.starts, 0)
    }

    func testHardFaultNeverDowngradesToRecoverableAndSurvivesRelaunch() throws {
        let f = fixture(); _ = try f.legacy()
        f.controller.block()
        f.controller.block(reason: .interruptedCleanup)
        let next = LidIntentController(defaults: f.defaults)
        XCTAssertEqual(next.intent?.pause?.reason, .hardFault)
        XCTAssertFalse(try next.recoverSavedPause(environment: f.recovery))
        XCTAssertEqual(f.checks, 0)
    }

    func testUnstableSnapshotsUseDurableBoundedBackoffAcrossRelaunchAndBoot() throws {
        let f = fixture(); _ = try f.legacy()
        f.onSnapshot = {
            f.snapshot = .init(context: .init(lidClosed: true, sleeping: false, locked: false,
                generation: UInt64(f.reads)), keyboards: [1: 1], mapping: f.snapshot.mapping)
        }
        for attempt in 1...3 {
            let next = LidIntentController(defaults: UserDefaults(suiteName: f.suite)!)
            XCTAssertFalse(try next.recoverSavedPause(environment: f.recovery))
            XCTAssertEqual(next.intent?.pause?.attempts, attempt)
            for _ in 0..<5 { XCTAssertFalse(try next.recoverSavedPause(environment: f.recovery)) }
            XCTAssertEqual(f.checks, attempt)
            f.now += pow(2, Double(attempt - 1))
        }
        f.boot = UUID(); f.now = 5; f.onSnapshot = nil
        XCTAssertFalse(try LidIntentController(defaults: f.defaults).recoverSavedPause(environment: f.recovery))
        XCTAssertEqual(f.checks, 3)
        XCTAssertTrue(f.controller.intent!.savedPause!.status.contains("Recovery unconfirmed"))
    }

    func testUnsafeSessionDoesNotConsumeBudgetAndPostCheckLockCannotClear() throws {
        let f = fixture(); _ = try f.legacy(); f.eligible = false
        XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
        XCTAssertEqual(f.checks, 0); XCTAssertNil(f.controller.intent?.pause)
        f.eligible = true; f.onSnapshot = { f.eligible = false }
        XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
        XCTAssertTrue(f.controller.intent!.blocked); XCTAssertEqual(f.controller.intent?.pause?.attempts, 1)
    }

    func testPersistenceFailureOrSilentWriteLossStopsBeforeSafetyAttempt() throws {
        for throwsFailure in [false, true] {
            let f = fixture(); _ = try f.legacy()
            let bytes = f.defaults.data(forKey: LidSessionIntent.preferenceKey)
            let controller = LidIntentController(defaults: f.defaults, writeIntent: { _ in
                if throwsFailure { throw CocoaError(.fileWriteNoPermission) }
            })
            XCTAssertThrowsError(try controller.recoverSavedPause(environment: f.recovery))
            XCTAssertEqual(f.checks, 0); XCTAssertEqual(f.reads, 0); XCTAssertEqual(f.starts, 0)
            XCTAssertEqual(f.defaults.data(forKey: LidSessionIntent.preferenceKey), bytes)
        }
    }

    func testAttemptRecordedBeforeVerifierAndClockSafetyCallbacksCannotReenter() throws {
        let f = fixture(); _ = try f.legacy()
        var environment = f.recovery
        environment.clock = {
            XCTAssertFalse(try! f.controller.recoverSavedPause(environment: f.recovery))
            return f.clock
        }
        environment.eligible = {
            XCTAssertFalse(try! f.controller.recoverSavedPause(environment: f.recovery))
            return true
        }
        environment.verify = {
            let relaunched = LidIntentController(defaults: f.defaults)
            XCTAssertEqual(relaunched.intent?.pause?.attempts, 1)
            XCTAssertEqual(relaunched.intent?.pause?.retryBoot, f.boot)
            XCTAssertEqual(relaunched.intent?.pause?.retryAfter, 101)
            return try f.qualifiedFixtureVerification()
        }
        XCTAssertTrue(try f.controller.recoverSavedPause(environment: environment))
    }

    func testEffectLockContentionWaitsBoundedlyWithoutReadingOrRepairingHardware() throws {
        let f = fixture(); _ = try f.legacy()
        _ = try ClosedEffectSession.locked(directory: f.directory, wait: false) {
            XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
        }
        XCTAssertEqual(f.reads, 0); XCTAssertEqual(f.controller.intent?.pause?.attempts, 1)
        XCTAssertEqual(f.controller.intent?.pause?.reason, .legacyUnknown)
        f.now = 101
        XCTAssertTrue(try f.controller.recoverSavedPause(environment: f.recovery))
    }

    func testClockBootChangeOrRollbackDuringVerificationCannotClearPause() throws {
        for reboot in [false, true] {
            let f = fixture(); _ = try f.legacy()
            f.onSnapshot = { if reboot { f.boot = UUID() } else { f.now = 0 } }
            XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
            XCTAssertTrue(f.controller.intent!.blocked)
            XCTAssertEqual(f.controller.intent?.pause?.attempts, 1)
            XCTAssertEqual(f.starts, 0)
        }
    }

    func testImpossibleSameBootBackoffBecomesActionableWithoutAnotherAttempt() throws {
        let f = fixture(); _ = try f.legacy()
        var intent = try XCTUnwrap(f.controller.intent)
        intent.pause = .init(reason: .legacyUnknown, attempts: 1,
                             retryBoot: f.boot, retryAfter: f.now + 86_400)
        try intent.save(f.defaults)
        XCTAssertTrue(intent.valid, "The malformed timing is structurally decodable")
        let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {},
            lidIntentEnvironment: f.session,
            hardwareApply: { _, _ in XCTFail("Untrusted timing cannot authorize an effect"); return .applied },
            lidPauseRecoveryEnvironment: f.recovery)
        model.controlWanted = true; model.tick()
        let paused = try XCTUnwrap(f.controller.intent)
        XCTAssertEqual(paused.id, intent.id); XCTAssertTrue(paused.blocked)
        XCTAssertEqual(paused.pause?.reason, .hardFault); XCTAssertEqual(paused.pause?.attempts, 1)
        XCTAssertEqual(paused.pause?.retryAfter, intent.pause?.retryAfter)
        XCTAssertTrue(paused.savedPause!.status.contains("timing could not be verified"))
        XCTAssertTrue(model.savedLidPauseNeedsReview)
        XCTAssertEqual(f.checks, 0); XCTAssertEqual(f.reads, 0); XCTAssertEqual(f.starts, 0)
        f.now += 100_000
        XCTAssertFalse(try LidIntentController(defaults: f.defaults).recoverSavedPause(environment: f.recovery))
        XCTAssertEqual(f.checks, 0, "Clock catch-up cannot silently reopen a hard pause")
    }

    func testBackoffPlausibilityPreservesNormalRelaunchAndBootChangeBudget() throws {
        for reboot in [false, true] {
            let f = fixture(); _ = try f.legacy()
            var intent = try XCTUnwrap(f.controller.intent)
            intent.pause = .init(reason: .legacyUnknown, attempts: 2,
                                 retryBoot: f.boot, retryAfter: f.now + 2)
            try intent.save(f.defaults)
            let next = LidIntentController(defaults: UserDefaults(suiteName: f.suite)!)
            if reboot {
                f.boot = UUID(); f.now = 5
            } else {
                XCTAssertFalse(try next.recoverSavedPause(environment: f.recovery))
                XCTAssertEqual(next.intent?.pause?.attempts, 2); XCTAssertEqual(f.checks, 0)
                f.now += 2
            }
            var environment = f.recovery
            environment.verify = {
                XCTAssertEqual(next.intent?.pause?.attempts, 3, "Neither relaunch nor reboot resets the budget")
                return try f.qualifiedFixtureVerification()
            }
            XCTAssertTrue(try next.recoverSavedPause(environment: environment))
        }
    }

    func testMalformedPauseMetadataNeverOptInsAndExhaustedCleanupCannotRetry() throws {
        let f = fixture(), id = try f.legacy()
        for pause: [String: Any] in [
            ["reason": "unknownFutureReason", "attempts": 0],
            ["reason": "interruptedCleanup", "attempts": -1],
            ["reason": "interruptedCleanup", "attempts": 4],
            ["reason": "interruptedCleanup", "attempts": 1, "retryAfter": 100]
        ] {
            let record: [String: Any] = ["version": 1, "id": id.uuidString, "durationSeconds": 0,
                                       "blocked": true, "pause": pause]
            f.defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: LidSessionIntent.preferenceKey)
            XCTAssertNil(f.controller.intent)
            XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
        }
        _ = try f.legacy(); f.controller.block(reason: .interruptedCleanup)
        for _ in 0..<3 { try f.controller.recordCleanupAttempt(clock: f.clock) }
        XCTAssertThrowsError(try f.controller.recordCleanupAttempt(clock: f.clock))
        XCTAssertEqual(f.controller.intent?.pause?.attempts, 3)
        XCTAssertEqual(f.checks, 0)
    }

    func testOffReplacementAndReentrantVerificationCannotResurrectOldIntent() throws {
        for replace in [false, true] {
            let f = fixture(), id = try f.legacy()
            f.onSnapshot = {
                XCTAssertFalse(try! f.controller.recoverSavedPause(environment: f.recovery))
                f.controller.disable()
                if replace { try! f.controller.enable(duration: .init(mode: .untilTurnedOff), environment: f.session) }
            }
            XCTAssertFalse(try f.controller.recoverSavedPause(environment: f.recovery))
            XCTAssertNotEqual(f.controller.intent?.id, id); XCTAssertEqual(f.checks, 1); XCTAssertEqual(f.starts, 0)
        }
    }

    func testActualModelChecksBeforeAnyEffectOrHelperAndNeverReentersVerification() throws {
        let f = fixture(); _ = try f.legacy()
        var sequence: [String] = []
        var recovery = f.recovery
        weak var observed: AppModel?
        recovery.verify = {
            sequence.append("verify")
            observed?.tick()
            XCTAssertEqual(sequence, ["verify"])
            return try f.qualifiedFixtureVerification()
        }
        var session = f.session
        let start = session.start
        session.start = { intent, lease in sequence.append("helper"); return try start(intent, lease) }
        let model = AppModel(demo: true, defaults: f.defaults,
            lidStopper: LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false }),
            hardwareRestore: {}, lidIntentEnvironment: session,
            hardwareApply: { _, _ in sequence.append("apply"); return .paused },
            lidPauseRecoveryEnvironment: recovery)
        observed = model; model.controlWanted = true; model.tick()
        XCTAssertEqual(sequence, ["verify", "apply", "helper"])
        XCTAssertFalse(f.controller.intent!.blocked); XCTAssertTrue(model.keepClosed)
        model.controlling = false; f.watcher.isRunning = false; _ = model.prepareQuit()
    }

    func testActualModelUnverifiedPauseStopsFramesAndManualWithdrawalCancelsRearm() throws {
        for withdraw in [false, true] {
            let f = fixture(); _ = try f.legacy()
            weak var observed: AppModel?
            var recovery = f.recovery
            recovery.verify = {
                f.checks += 1
                if withdraw { observed?.setControl(false); return .verified }
                return .retryLater("Waiting for native safety state.")
            }
            let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {},
                lidIntentEnvironment: f.session,
                hardwareApply: { _, _ in XCTFail("Unverified or withdrawn recovery applied"); return .applied },
                lidPauseRecoveryEnvironment: recovery)
            observed = model; model.controlWanted = true
            for _ in 0..<10 { model.tick() }
            XCTAssertEqual(f.checks, 1); XCTAssertEqual(f.starts, 0)
            XCTAssertTrue(f.controller.intent!.blocked)
            if withdraw { XCTAssertFalse(model.controlWanted) }
        }
    }

    func testOpenLidHardPauseExplainsStoppedEffectsAndExposesReview() throws {
        let f = fixture(); _ = try f.legacy(); f.closed = false
        f.controller.block()
        let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {},
            lidIntentEnvironment: f.session,
            hardwareApply: { _, _ in XCTFail("Hard failure cannot apply with the lid open either"); return .applied },
            lidPauseRecoveryEnvironment: f.recovery)
        model.controlWanted = true; model.tick()
        XCTAssertTrue(model.savedLidPauseNeedsReview)
        XCTAssertTrue(model.status.contains("Restore your light"))
        XCTAssertTrue(model.status.contains("off and on"))
        XCTAssertFalse(model.status.contains("Connecting"))
        XCTAssertEqual(f.checks, 0); XCTAssertEqual(f.starts, 0)
    }

    func testQuitDuringSafetyVerificationWithdrawsAutomaticRearm() throws {
        let f = fixture(); _ = try f.legacy()
        weak var observed: AppModel?
        var recovery = f.recovery
        recovery.verify = {
            f.checks += 1
            XCTAssertFalse(observed!.prepareQuit())
            return try f.verifier.verify()
        }
        let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {},
            lidIntentEnvironment: f.session,
            hardwareApply: { _, _ in XCTFail("Quit cannot be followed by an automatic effect"); return .applied },
            lidPauseRecoveryEnvironment: recovery)
        observed = model; model.controlWanted = true; model.tick()
        XCTAssertTrue(f.controller.intent!.blocked); XCTAssertFalse(model.controlWanted)
        for _ in 0..<5 { f.now += 10; model.tick() }
        XCTAssertEqual(f.checks, 1); XCTAssertEqual(f.starts, 0)
        XCTAssertTrue(model.prepareQuit())
    }

    func testBusyQuitDoesNotBypassOffRestorationConfirmation() {
        let f = fixture()
        var restores = 0, confirmations = 0
        let model = AppModel(demo: true, defaults: f.defaults,
            hardwareRestore: { restores += 1 }, hardwareApply: { _, _ in .applied })
        model.enabled = false; model.controlling = true; model.controlWanted = true
        XCTAssertTrue(model.withHardwareApply {
            XCTAssertFalse(model.prepareQuit(confirmOff: { confirmations += 1; return .alertFirstButtonReturn }))
        })
        model.tick()
        XCTAssertEqual(restores, 0); XCTAssertEqual(confirmations, 0)
        XCTAssertTrue(model.controlling)
        XCTAssertFalse(model.prepareQuit(confirmOff: { confirmations += 1; return .alertSecondButtonReturn }))
        XCTAssertEqual(confirmations, 1); XCTAssertEqual(restores, 0)
        model.controlling = false
    }

    func testInterruptedOwnedCleanupSuccessRetainsUnconfirmedPauseAndBudget() throws {
        let f = fixture(); _ = try f.legacy()
        // Begin with a healthy modern choice rather than a prior unknown pause.
        try f.controller.enable(duration: .init(mode: .untilTurnedOff), environment: f.session)
        let id = f.controller.intent!.id
        var fails = true, restores = 0
        let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {
            restores += 1
            if fails { throw RuntimeServices.failure("Interrupted native cleanup") }
        }, hardwareApply: { _, _ in .applied })
        var now = 0.0
        model.recoveryClock = { now }; model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true)
        model.releaseHardware()
        XCTAssertEqual(f.controller.intent?.pause?.reason, .interruptedCleanup)
        XCTAssertTrue(f.controller.intent!.blocked)
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        now = 1; model.tick()
        XCTAssertEqual(f.controller.intent?.pause?.attempts, 1)
        XCTAssertEqual(LidIntentController(defaults: f.defaults).intent?.pause?.attempts, 1)
        fails = false; now = 2; model.tick()
        XCTAssertEqual(restores, 3); XCTAssertEqual(f.controller.intent?.id, id)
        XCTAssertTrue(f.controller.intent!.blocked)
        XCTAssertEqual(f.controller.intent?.pause?.reason, .interruptedCleanup)
        XCTAssertEqual(f.controller.intent?.pause?.attempts, 2)
        XCTAssertTrue(model.status.contains("Recovery unconfirmed"))
        model.controlling = false
    }

    func testWithdrawalDuringFailedOwnedRetryDoesNotRequeueRecovery() throws {
        let f = fixture()
        try f.controller.enable(duration: .init(mode: .untilTurnedOff), environment: f.session)
        var restores = 0, now = 0.0
        weak var observed: AppModel?
        let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {
            restores += 1
            if restores == 2 { observed?.setControl(false) }
            throw RuntimeServices.failure("Cleanup still interrupted")
        }, hardwareApply: { _, _ in XCTFail("Withdrawn retry cannot resume effects"); return .applied })
        observed = model; model.recoveryClock = { now }
        model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true); model.releaseHardware()
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        now = 1; model.tick()
        XCTAssertFalse(model.automaticRecoveryPending); XCTAssertFalse(model.controlWanted)
        // Drain the one requested final cleanup, never another automatic rearm.
        model.tick(); let finalRestores = restores
        for _ in 0..<10 { now += 5; model.tick() }
        XCTAssertEqual(restores, finalRestores); XCTAssertFalse(model.automaticRecoveryPending)
        model.controlling = false
    }

    func testOffDuringSuccessfulCleanupCannotApplyPreRestoreBrightness() {
        let f = fixture()
        var restores = 0, now = 0.0, levels: [Double] = []
        weak var observed: AppModel?
        let model = AppModel(demo: true, defaults: f.defaults, hardwareRestore: {
            restores += 1
            if restores == 1 { throw RuntimeServices.failure("Interrupted cleanup") }
            observed?.enabled = false
        }, hardwareApply: { level, _ in levels.append(level); return .applied })
        observed = model; model.mode = .steady; model.brightness = 1
        model.recoveryClock = { now }; model.controlWanted = true; model.controlling = true
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true); model.releaseHardware()
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        now = 1; model.tick()
        XCTAssertEqual(restores, 2); XCTAssertTrue(levels.isEmpty)
        model.tick()
        XCTAssertEqual(levels, [0]); XCTAssertFalse(model.enabled)
        model.controlling = false
    }
}
