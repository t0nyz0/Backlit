import XCTest
@testable import Backlit

@MainActor final class LightReadinessTests: XCTestCase {
    private func fixture(_ apply: @escaping (Double, Bool) throws -> FadeApplyResult = { _, _ in .applied }) -> (AppModel, UserDefaults, String) {
        let suite = "Backlit.LightReadiness." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {}, hardwareApply: apply)
        model.controlWanted = true
        model.controlling = true
        return (model, defaults, suite)
    }

    func testOwnershipWithoutAppliedFrameCannotAnnounceReady() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.announceLightReadiness()
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice)
    }

    func testOnlyAppliedUnpausedFrameAnnouncesReady() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        for result in [FadeApplyResult.waiting, .paused, .applied] {
            model.updateMusicHardwareReadiness { result }
            model.announceLightReadiness()
            XCTAssertEqual(model.lightReady, result == .applied)
            XCTAssertEqual(model.notice, result == .applied ? "Your light is ready." : nil)
        }
        model.pausedReason = "Paused with your display"
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice, "A safety pause hides a previous success immediately")
    }

    func testLaterWaitingOrPausedFramePermanentlyInvalidatesSuccess() {
        for next in [FadeApplyResult.waiting, .paused] {
            let (model, defaults, suite) = fixture()
            defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
            model.updateMusicHardwareReadiness { .applied }
            model.announceLightReadiness()
            model.updateMusicHardwareReadiness { next }
            XCTAssertNil(model.notice)
            model.updateMusicHardwareReadiness { .applied }
            XCTAssertNil(model.notice, "Old repair success must not reappear after a later output interruption")
        }
    }

    func testLaterHardwareFailureInvalidatesSuccessAndKeepsHardPause() {
        let (model, defaults, suite) = fixture { _, _ in throw RuntimeServices.failure("Closed-lid light output is unavailable.") }
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.updateMusicHardwareReadiness { .applied }
        model.announceLightReadiness()
        model.tick()
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.lightReady)
        XCTAssertNotNil(model.hardwareFailure)
        XCTAssertFalse(model.controlWanted)
        model.error = nil
        XCTAssertTrue(model.status.contains("Logo control unavailable"))
    }

    func testSavedHardPausePreventsReadyWithoutChangingIntent() throws {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.updateMusicHardwareReadiness { .applied }
        model.announceLightReadiness()
        var intent = LidSessionIntent(duration: .init(mode: .untilTurnedOff))
        intent.blocked = true
        try intent.save(defaults)
        let saved = defaults.data(forKey: LidSessionIntent.preferenceKey)
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice)
        model.announceLightReadiness()
        XCTAssertEqual(defaults.data(forKey: LidSessionIntent.preferenceKey), saved)
        XCTAssertEqual(model.status, LidSavedPause.unconfirmedStatus)
    }

    func testExplicitOffDoesNotAnnounceReadyForAppliedZeroFrame() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.updateMusicHardwareReadiness { .applied }
        model.announceLightReadiness()
        model.enabled = false
        model.updateMusicHardwareReadiness { .applied }
        model.announceLightReadiness()
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice)
        model.enabled = true
        XCTAssertNil(model.notice)
    }

    func testCleanupAloneNeverAnnouncesReadyAndOtherNoticesArePreserved() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.updateMusicHardwareReadiness { .applied }
        model.announceLightReadiness()
        model.withHardwareRecovery {}
        model.announceLightReadiness()
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice)
        model.notice = "Native handback remains unconfirmed."
        model.announceLightReadiness()
        XCTAssertEqual(model.notice, "Native handback remains unconfirmed.")
    }

    func testSuccessfulFrameFlowCanAnnounceReady() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.tick()
        model.announceLightReadiness()
        XCTAssertTrue(model.lightReady)
        XCTAssertEqual(model.notice, "Your light is ready.")
    }

    func testAppliedClosedLidFrameCanBeReadyWithSleepingDisplayButNotSleepingMac() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.keepClosed = true
        model.updateMusicHardwareReadiness { .applied }
        model.setPreviewInputSession(lidClosed: true, screenAsleep: true)
        model.announceLightReadiness()
        XCTAssertTrue(model.lightReady)
        XCTAssertEqual(model.notice, "Your light is ready.")
        model.setPreviewInputSession(lidClosed: true, screenAsleep: true, systemAsleep: true)
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice)
    }

    func testSleepAndWithdrawnControlHidePriorReadyBanner() {
        let (model, defaults, suite) = fixture()
        defer { model.controlling = false; defaults.removePersistentDomain(forName: suite) }
        model.updateMusicHardwareReadiness { .applied }
        model.announceLightReadiness()
        model.setPreviewInputSession(lidClosed: false, screenAsleep: true, systemAsleep: true)
        XCTAssertFalse(model.lightReady)
        XCTAssertNil(model.notice)
        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        model.setControl(false)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.lightReady)
    }
}
