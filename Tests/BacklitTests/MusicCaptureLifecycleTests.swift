import XCTest
@testable import Backlit

@MainActor final class MusicCaptureLifecycleTests: XCTestCase {
    @MainActor private final class Fixture {
        var mode: GlowMode = .steady
        var enabled = true
        var eligible = true
        var preview = false
        var failed = false
        var failStart = false
        var starts = 0, stops = 0, failures = 0
        lazy var driver = AudioSessionDriver(start: {
            self.starts += 1
            if self.failStart { throw NSError(domain: "fixture.permission-denied", code: 1) }
        }, stop: { self.stops += 1 }, eligible: {
            !self.preview && self.mode == .music && self.enabled && self.eligible
        }, changed: { _ in }, failed: { _ in self.failed = true; self.failures += 1 })
        func sync() {
            switch MusicCapturePolicy.action(mode: mode, enabled: enabled, eligible: eligible,
                preview: preview, failed: failed, active: driver.state == .running || driver.state == .starting) {
            case .start: driver.requestStart()
            case .stop: driver.requestStop()
            case .none: break
            }
        }
    }

    func testMusicSelectionStartsAndLeavingStopsWithoutSeparateButton() async {
        let f = Fixture(); f.sync(); XCTAssertEqual(f.starts, 0)
        f.mode = .music; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.starts, 1); XCTAssertEqual(f.driver.state, .running)
        for _ in 0..<100 { f.sync() }
        XCTAssertEqual(f.starts, 1)
        f.mode = .breathe; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.stops, 1); XCTAssertEqual(f.driver.state, .idle)
    }

    func testDisabledOrPausedMusicWaitsThenAutomaticallyResumes() async {
        let f = Fixture(); f.mode = .music; f.enabled = false
        f.sync(); XCTAssertEqual(f.starts, 0)
        f.enabled = true; f.eligible = false; f.sync(); XCTAssertEqual(f.starts, 0)
        f.eligible = true; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.starts, 1)
        f.eligible = false; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.stops, 1)
        f.eligible = true; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.starts, 2)
        f.enabled = false; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.stops, 2)
    }

    func testDeniedStartDoesNotPromptAgainOnEveryFrameAndAllowsExplicitRetry() async {
        let f = Fixture(); f.mode = .music; f.failStart = true
        f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertTrue(f.failed); XCTAssertEqual(f.failures, 1); XCTAssertEqual(f.starts, 1)
        for _ in 0..<1_000 { f.sync() }
        await f.driver.waitForCurrentWork(); XCTAssertEqual(f.starts, 1)
        f.failStart = false; f.failed = false; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.starts, 2); XCTAssertEqual(f.driver.state, .running)
        f.mode = .steady; f.sync(); await f.driver.waitForCurrentWork()
    }

    func testPreviewNeverRequestsCaptureOrPermission() async {
        let f = Fixture(); f.preview = true; f.mode = .music
        for _ in 0..<100 { f.sync() }
        await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.starts, 0); XCTAssertEqual(f.stops, 0); XCTAssertEqual(f.driver.workerCount, 0)
    }

    func testPendingStartIsCancelledWhenMusicIsLeftImmediately() async {
        let f = Fixture(); f.mode = .music; f.sync()
        f.mode = .steady; f.sync(); await f.driver.waitForCurrentWork()
        XCTAssertEqual(f.driver.state, .idle)
        XCTAssertEqual(f.starts, 0, "Cancellation before backend entry cannot request permission")
    }

    func testPreviewModelSelectionAndReselectionStayCaptureFree() {
        let name = "local.backlit.test.music-capture." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let model = AppModel(demo: true, defaults: defaults)
        defer { _ = model.prepareQuit(); defaults.removePersistentDomain(forName: name) }
        model.mode = .music; model.tick()
        XCTAssertFalse(model.audioStarting); XCTAssertFalse(model.audioRunning)
        model.audioPermissionHelp = true; model.tick()
        XCTAssertTrue(model.audioPermissionHelp, "Routine ticks must not clear a failed-attempt gate")
        model.mode = .steady; model.mode = .music
        XCTAssertFalse(model.audioPermissionHelp, "Explicit re-selection permits a fresh attempt")
        model.tick(); XCTAssertFalse(model.audioStarting); XCTAssertFalse(model.audioRunning)
    }

    @MainActor private final class Observations {
        var available = true
        var locked = false
        var lidClosed = false
        func read() -> AppModel.MusicCaptureObservation {
            .init(deviceAvailable: available, locked: locked, lidClosed: lidClosed)
        }
    }

    private func eligibilityModel(_ observations: Observations) -> AppModel {
        let name = "local.backlit.test.music-eligibility." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let model = AppModel(demo: true, defaults: defaults, musicCaptureObservation: observations.read)
        addTeardownBlock { @MainActor in
            // Flags are fixtures; these tests never acquire hardware ownership.
            model.controlling = false; model.controlWanted = false
            _ = model.prepareQuit(); defaults.removePersistentDomain(forName: name)
        }
        model.mode = .music; model.enabled = true
        model.controlWanted = true; model.controlling = true
        return model
    }

    func testActualEligibilityRequiresSuccessfulRequestedOwnership() {
        let observed = Observations(), model = eligibilityModel(observed)
        XCTAssertFalse(model.musicCaptureAllowed, "Music selection alone cannot authorize capture")
        model.updateMusicHardwareReadiness {
            XCTAssertFalse(model.musicCaptureAllowed, "Capture must wait until hardware setup completes")
            return .applied
        }
        XCTAssertTrue(model.musicCaptureAllowed)
        model.controlWanted = false
        XCTAssertFalse(model.musicCaptureAllowed)
        model.controlWanted = true; model.controlling = false
        XCTAssertFalse(model.musicCaptureAllowed)
        model.controlling = true; model.enabled = false
        XCTAssertFalse(model.musicCaptureAllowed)
    }

    func testActualEligibilityRejectsUnavailableAndFailedOrRecoveringHardware() {
        let observed = Observations(), model = eligibilityModel(observed)
        model.updateMusicHardwareReadiness { .applied }
        XCTAssertTrue(model.musicCaptureAllowed)
        observed.available = false
        XCTAssertFalse(model.musicCaptureAllowed)
        observed.available = true
        XCTAssertThrowsError(try model.updateMusicHardwareReadiness {
            throw NSError(domain: "fixture.hardware-needs-recovery", code: 1)
        })
        XCTAssertFalse(model.musicCaptureAllowed, "Failure invalidates otherwise-owned hardware")
        model.updateMusicHardwareReadiness { .applied }
        XCTAssertTrue(model.musicCaptureAllowed)
        XCTAssertTrue(model.withHardwareRecovery { XCTAssertFalse(model.musicCaptureAllowed) })
        XCTAssertFalse(model.musicCaptureAllowed, "Restore does not reestablish lighting ownership")
    }

    func testActualEligibilityNeverTreatsClosedLidPermissionAsScreenUnlock() {
        let observed = Observations(), model = eligibilityModel(observed)
        model.updateMusicHardwareReadiness { .applied }
        model.keepClosed = true; observed.lidClosed = true
        XCTAssertTrue(model.musicCaptureAllowed)
        observed.locked = true
        XCTAssertFalse(model.musicCaptureAllowed)
        observed.lidClosed = false
        XCTAssertFalse(model.musicCaptureAllowed)
        observed.locked = false; model.pausedReason = "Session inactive"
        XCTAssertFalse(model.musicCaptureAllowed)
    }

    func testActualEligibilityStartsOnlyAfterAppliedFrameAndStopsForWaitingOrPausedFade() async {
        let observed = Observations(), model = eligibilityModel(observed)
        var starts = 0, stops = 0
        let driver = AudioSessionDriver(start: { starts += 1 }, stop: { stops += 1 },
            eligible: { model.musicCaptureAllowed }, changed: { _ in }, failed: { _ in XCTFail("Unexpected fixture failure") })
        func sync() {
            switch MusicCapturePolicy.action(mode: model.mode, enabled: model.enabled,
                eligible: model.musicCaptureAllowed, preview: false, failed: false,
                active: driver.state == .starting || driver.state == .running) {
            case .start: driver.requestStart()
            case .stop: driver.requestStop()
            case .none: break
            }
        }
        model.updateMusicHardwareReadiness { .waiting }
        sync(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 0); XCTAssertFalse(model.musicCaptureAllowed)
        model.updateMusicHardwareReadiness { .applied }
        sync(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 1); XCTAssertEqual(driver.state, .running)
        for result in [FadeApplyResult.paused, .waiting] {
            model.updateMusicHardwareReadiness { result }
            sync(); await driver.waitForCurrentWork()
            XCTAssertFalse(model.musicCaptureAllowed); XCTAssertEqual(driver.state, .idle)
            XCTAssertTrue(model.controlWanted); XCTAssertTrue(model.controlling)
        }
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 1)
        model.updateMusicHardwareReadiness { .applied }
        sync(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 2); XCTAssertEqual(driver.state, .running)
        driver.requestStop(); await driver.waitForCurrentWork()
    }
}
