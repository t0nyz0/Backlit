import XCTest
@testable import Backlit

/// In Music every beat that crosses zero produces a frame that is waiting to
/// observe its output. Capture must survive those frames; before this it was
/// stopped and restarted about twice a second.
@MainActor final class MusicReadinessGraceTests: XCTestCase {
    private func model() -> (AppModel, () -> Void) {
        let name = "local.backlit.test.music-grace." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        let model = AppModel(demo: true, defaults: defaults,
            musicCaptureObservation: { .init(deviceAvailable: true, locked: false, lidClosed: false) })
        model.mode = .music; model.enabled = true
        model.controlWanted = true; model.controlling = true
        return (model, {
            model.controlling = false; model.controlWanted = false
            _ = model.prepareQuit(); defaults.removePersistentDomain(forName: name)
        })
    }

    func testBeatByBeatWaitingFramesNeverRestartCapture() async {
        let (model, cleanup) = model(); defer { cleanup() }
        var time = 100.0; model.recoveryClock = { time }
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
        model.updateMusicHardwareReadiness { .applied }
        sync(); await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 1)
        // Sixty seconds of 20 Hz frames where every other beat waits briefly.
        for frame in 0..<1200 {
            time += 0.05
            let result: FadeApplyResult = frame % 8 < 3 ? .waiting : .applied
            model.updateMusicHardwareReadiness { result }
            XCTAssertTrue(model.musicCaptureAllowed, "frame \(frame)")
            sync()
        }
        await driver.waitForCurrentWork()
        XCTAssertEqual(starts, 1); XCTAssertEqual(stops, 0); XCTAssertEqual(driver.state, .running)
        driver.requestStop(); await driver.waitForCurrentWork()
    }

    func testAWaitThatPersistsStillWithdrawsReadiness() {
        let (model, cleanup) = model(); defer { cleanup() }
        var time = 10.0; model.recoveryClock = { time }
        model.updateMusicHardwareReadiness { .applied }
        time += AppModel.musicReadinessGrace
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertTrue(model.musicCaptureAllowed, "Still inside the grace period")
        time += 0.05
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed, "Output has not been observed for too long")
        // Waiting can never earn readiness back; only an applied frame can.
        time += 0.05
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed)
        model.updateMusicHardwareReadiness { .applied }
        XCTAssertTrue(model.musicCaptureAllowed)
    }

    func testWaitingAloneNeverMakesHardwareReady() {
        let (model, cleanup) = model(); defer { cleanup() }
        for _ in 0..<5 { model.updateMusicHardwareReadiness { .waiting } }
        XCTAssertFalse(model.musicCaptureAllowed)
    }

    func testPauseErrorAndRecoveryWithdrawReadinessImmediately() {
        let (model, cleanup) = model(); defer { cleanup() }
        var time = 10.0; model.recoveryClock = { time }
        model.updateMusicHardwareReadiness { .applied }
        model.updateMusicHardwareReadiness { .paused }
        XCTAssertFalse(model.musicCaptureAllowed)
        time += 0.05
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed, "A wait after a pause is not covered by the grace")

        model.updateMusicHardwareReadiness { .applied }
        XCTAssertThrowsError(try model.updateMusicHardwareReadiness { throw NSError(domain: "fixture", code: 1) })
        XCTAssertFalse(model.musicCaptureAllowed)
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed, "A wait after a failure is not covered by the grace")

        model.updateMusicHardwareReadiness { .applied }
        XCTAssertTrue(model.withHardwareRecovery { })
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed, "A wait after a recovery is not covered by the grace")
    }

    func testAClockThatGoesBackwardsFailsClosed() {
        let (model, cleanup) = model(); defer { cleanup() }
        var time = 50.0; model.recoveryClock = { time }
        model.updateMusicHardwareReadiness { .applied }
        time = 40
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed)
        time = .nan
        model.updateMusicHardwareReadiness { .applied }
        model.updateMusicHardwareReadiness { .waiting }
        XCTAssertFalse(model.musicCaptureAllowed)
    }
}
