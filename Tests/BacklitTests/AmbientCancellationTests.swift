import AppKit
import XCTest
@testable import Backlit

@MainActor final class AmbientCancellationTests: XCTestCase {
    private func model(restore: @escaping () throws -> Void = {},
                       apply: @escaping (Double, Bool) throws -> FadeApplyResult = { _, _ in .applied },
                       authorize: @escaping (Bool) throws -> Void) -> (AppModel, UserDefaults) {
        let suite = "local.backlit.test.ambient." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults,
            lidStopper: LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false }),
            hardwareRestore: restore, hardwareApply: apply, ambientAuthorization: authorize)
        model.controlWanted = true; model.controlling = true
        return (model, defaults)
    }

    func testCancellationRestoresPriorIntentAfterCleanupAndPreservesPreferences() {
        var events: [String] = []
        let (m, defaults) = model(restore: { events.append("restore") },
            apply: { _, _ in events.append("apply"); return .applied },
            authorize: { _ in events.append("authorize"); throw AmbientAuthorizationFailure.cancelled })
        m.brightness = 0.37; m.error = "Unrelated warning"
        m.setAmbient(true)
        XCTAssertEqual(events, ["restore", "authorize", "apply"])
        XCTAssertTrue(m.controlWanted); XCTAssertTrue(m.controlling)
        XCTAssertFalse(m.ambientUnlocked); XCTAssertNil(defaults.object(forKey: "ambientUnlocked"))
        XCTAssertEqual(m.brightness, 0.37); XCTAssertEqual(m.error, "Unrelated warning")
        XCTAssertFalse(m.hardwareOperationInProgress)
        m.controlling = false
    }

    func testCancellationDoesNotStartPreviouslyUnownedLight() {
        var applies = 0
        let (m, _) = model(apply: { _, _ in applies += 1; return .applied },
                           authorize: { _ in throw AmbientAuthorizationFailure.cancelled })
        m.controlWanted = false; m.controlling = false
        m.setAmbient(true)
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
    }

    func testFailedCleanupNeverShowsAuthorizationOrResumes() {
        var authorizations = 0, applies = 0
        let (m, _) = model(restore: { throw RuntimeServices.failure("Cleanup failed") },
            apply: { _, _ in applies += 1; return .applied },
            authorize: { _ in authorizations += 1 })
        m.setAmbient(true)
        XCTAssertEqual(authorizations, 0); XCTAssertEqual(applies, 0)
        XCTAssertFalse(m.controlWanted); XCTAssertTrue(m.controlling)
        XCTAssertEqual(m.error, "Cleanup failed"); XCTAssertFalse(m.ambientUnlocked)
        m.controlling = false
    }

    func testUnknownHelperFailureRemainsPausedBecauseWritesMayHaveOccurred() {
        var applies = 0
        let (m, defaults) = model(apply: { _, _ in applies += 1; return .applied },
            authorize: { _ in throw AmbientAuthorizationFailure.failed("Helper result uncertain") })
        m.setAmbient(true)
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
        XCTAssertFalse(m.ambientUnlocked); XCTAssertNil(defaults.object(forKey: "ambientUnlocked"))
        XCTAssertEqual(m.error, "Helper result uncertain")
    }

    func testSuccessfulAuthorizationCommitsPreferenceAndRestoresPriorIntent() {
        let (m, defaults) = model(authorize: { XCTAssertTrue($0) })
        m.setAmbient(true)
        XCTAssertTrue(m.ambientUnlocked); XCTAssertTrue(defaults.bool(forKey: "ambientUnlocked"))
        XCTAssertTrue(m.controlWanted); XCTAssertTrue(m.controlling)
        m.controlling = false
    }

    func testDialogPumpedCallbacksCannotDuplicatePromptApplyOrRestore() {
        var current: AppModel!, authorizations = 0, restores = 0, applies = 0
        let (m, _) = model(restore: { restores += 1 },
            apply: { _, _ in applies += 1; return .applied }, authorize: { _ in
                authorizations += 1
                XCTAssertTrue(current.hardwareOperationInProgress)
                current.tick(); current.setAmbient(false); current.releaseHardware(); current.setControl(true)
                XCTAssertEqual(authorizations, 1); XCTAssertEqual(restores, 1); XCTAssertEqual(applies, 0)
                throw AmbientAuthorizationFailure.cancelled
            })
        current = m; m.setAmbient(true)
        XCTAssertEqual(authorizations, 1); XCTAssertEqual(restores, 1); XCTAssertEqual(applies, 1)
        m.controlling = false
    }

    func testOffDuringAuthorizationWinsOverCancellationResume() {
        var current: AppModel!, applies = 0
        let (m, _) = model(apply: { _, _ in applies += 1; return .applied }, authorize: { _ in
            current.setControl(false)
            throw AmbientAuthorizationFailure.cancelled
        })
        current = m; m.setAmbient(true)
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
    }

    func testQuitDuringAuthorizationWinsOverCancellationResume() {
        var current: AppModel!, applies = 0
        let (m, _) = model(apply: { _, _ in applies += 1; return .applied }, authorize: { _ in
            XCTAssertFalse(current.prepareQuit())
            throw AmbientAuthorizationFailure.cancelled
        })
        current = m; m.setAmbient(true)
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
    }

    func testOffDuringCleanupPreventsPromptAndResume() {
        var current: AppModel!, authorizations = 0
        let (m, _) = model(restore: { current.setControl(false) }, authorize: { _ in authorizations += 1 })
        current = m; m.setAmbient(true)
        XCTAssertEqual(authorizations, 0); XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling)
    }

    func testPreviewCannotUseInjectedAuthorizationWithoutInertHardware() {
        let suite = "local.backlit.test.ambient.preview." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = AppModel(demo: true, defaults: defaults,
                         ambientAuthorization: { _ in XCTFail("Preview must not authorize") })
        m.setAmbient(true)
        XCTAssertFalse(m.ambientUnlocked)
    }

    func testActiveLidOwnerPreventsPromptAndPreservesIntent() {
        final class Stopped: LidWatcherProcess {
            var isRunning: Bool { false }
            var terminationStatus: Int32 { 0 }
            func terminate() { XCTFail("Inert process already stopped") }
        }
        var authorizations = 0, restores = 0
        let (m, _) = model(restore: { restores += 1 }, authorize: { _ in authorizations += 1 })
        XCTAssertTrue(m.adoptLidWatcher(Stopped(), lease: URL(fileURLWithPath: "/tmp/inert-ambient-lease")))
        m.setAmbient(true)
        XCTAssertEqual(authorizations, 0); XCTAssertEqual(restores, 0)
        XCTAssertTrue(m.controlWanted); XCTAssertTrue(m.controlling)
        m.controlling = false; m.stopLid()
    }

    func testReentrantPowerIntentCannotResumeAfterUnknownHelperFailure() {
        var current: AppModel!, applies = 0
        let (m, _) = model(apply: { _, _ in applies += 1; return .applied }, authorize: { _ in
            // Reproduce the live power-toggle side effect directly. Preview's
            // enabled observer intentionally does not own real hardware.
            current.enabled.toggle(); current.controlWanted = true
            current.tick()
            throw AmbientAuthorizationFailure.failed("Uncertain helper result")
        })
        current = m; m.setAmbient(true)
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
        m.tick(); XCTAssertEqual(applies, 0)
    }

    func testReentrantPowerIntentAfterQuitCannotOverrideCancellationVeto() {
        var current: AppModel!, applies = 0
        let (m, _) = model(apply: { _, _ in applies += 1; return .applied }, authorize: { _ in
            XCTAssertFalse(current.prepareQuit())
            current.enabled.toggle(); current.controlWanted = true
            throw AmbientAuthorizationFailure.cancelled
        })
        current = m; m.setAmbient(true)
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
        m.tick(); XCTAssertEqual(applies, 0)
    }

    func testReentrantPowerIntentAfterOffCannotOverrideSuccessfulAuthorizationVeto() {
        var current: AppModel!, applies = 0
        let (m, defaults) = model(apply: { _, _ in applies += 1; return .applied }, authorize: { _ in
            current.setControl(false)
            current.enabled.toggle(); current.controlWanted = true
        })
        current = m; m.setAmbient(true)
        XCTAssertTrue(m.ambientUnlocked); XCTAssertTrue(defaults.bool(forKey: "ambientUnlocked"))
        XCTAssertFalse(m.controlWanted); XCTAssertFalse(m.controlling); XCTAssertEqual(applies, 0)
        m.tick(); XCTAssertEqual(applies, 0)
    }

    func testOnlyExplicitAppleScriptCancellationIsSafeToResume() {
        let cancelled = AmbientAuthorizationFailure(scriptError: [NSAppleScript.errorNumber: -128])
        guard case .cancelled = cancelled else { return XCTFail("Expected explicit cancellation") }
        for details: NSDictionary in [[:], [NSAppleScript.errorNumber: 1],
                                     [NSAppleScript.errorMessage: "Authorization was cancelled."]] {
            guard case .failed = AmbientAuthorizationFailure(scriptError: details) else {
                return XCTFail("Message text or missing code must not prove cancellation")
            }
        }
    }
}
