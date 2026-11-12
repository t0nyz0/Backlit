import XCTest
@testable import Backlit

final class StatusPresentationTests: XCTestCase {
    func testStatusMarkerHasDistinctOffAndVisibleLowEndpoint() {
        XCTAssertEqual(StatusIconGeometry.step(for: 0), 0)
        XCTAssertNil(StatusIconGeometry.marker(at: 0))
        XCTAssertEqual(StatusIconGeometry.step(for: 0.01), 1)
        XCTAssertGreaterThanOrEqual(StatusIconGeometry.marker(at: 1)!.width, 1.8)
        XCTAssertEqual(StatusIconGeometry.marker(at: 100), StatusIconGeometry.interior)
        XCTAssertEqual(StatusIconGeometry.step(for: .nan), 0)
        var previous: CGFloat = 0
        for step in 1...100 {
            let marker = StatusIconGeometry.marker(at: step)!
            XCTAssertGreaterThanOrEqual(marker.width, previous)
            XCTAssertEqual(marker.midX, StatusIconGeometry.interior.midX, accuracy: 0.0001)
            XCTAssertEqual(marker.midY, StatusIconGeometry.interior.midY, accuracy: 0.0001)
            previous = marker.width
        }
    }

    @MainActor func testStartupFailureRemainsVisibleAfterAlertDismissalAndClearsOnlyOnSuccess() {
        let suite = "Backlit.StartupStatus." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var fails = true
        var writes = 0
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {}, hardwareApply: { _, _ in
            writes += 1
            if fails { throw RuntimeServices.failure("Keyboard state unavailable") }
            return .applied
        })
        model.controlWanted = true
        model.tick()
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(model.controlling)
        XCTAssertFalse(model.controlWanted)
        model.error = nil
        XCTAssertEqual(model.hardwareFailure, "Keyboard state unavailable")
        XCTAssertTrue(model.status.contains("Logo control unavailable"))
        model.tick()
        XCTAssertEqual(writes, 1, "Failure must not loop hardware retries")
        fails = false
        model.controlWanted = true
        model.tick()
        XCTAssertNil(model.hardwareFailure)
        XCTAssertTrue(model.controlling)
        model.controlling = false
    }

    @MainActor func testClosedLidErrorPauseIsVisibleWithoutChangingIntentOrRuntimePause() throws {
        let suite = "Backlit.LidPauseStatus." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var intent = LidSessionIntent(duration: .init(mode: .untilTurnedOff))
        intent.blocked = true
        try intent.save(defaults)
        let saved = defaults.data(forKey: LidSessionIntent.preferenceKey)
        let model = AppModel(demo: true, defaults: defaults, hardwareApply: { _, _ in
            XCTFail("Reading status must not apply hardware")
            return .applied
        })
        model.setPreviewInputSession(lidClosed: true, screenAsleep: false)
        model.error = nil // Dismissing an alert does not remove the saved pause.
        for _ in 0..<3 {
            XCTAssertEqual(model.status, LidSavedPause.unconfirmedStatus)
        }
        XCTAssertNil(model.pausedReason)
        XCTAssertEqual(defaults.data(forKey: LidSessionIntent.preferenceKey), saved)
        XCTAssertTrue(model.lidRequested)
        XCTAssertFalse(model.keepClosed)
        XCTAssertFalse(model.controlWanted)
        XCTAssertFalse(model.controlling)

        model.setPreviewInputSession(lidClosed: false, screenAsleep: false)
        XCTAssertEqual(model.status, intent.savedPause?.status, "An open lid must explain the recovery gate too")
        XCTAssertEqual(LidSessionIntent.load(defaults), intent)
    }

    @MainActor func testClosedLidErrorDoesNotMaskExplicitOffOrCurrentSafetyPause() throws {
        let suite = "Backlit.LidPauseStatus." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "enabled")
        let model = AppModel(demo: true, defaults: defaults, hardwareApply: { _, _ in
            XCTFail("Reading status must not apply hardware")
            return .applied
        })
        model.setPreviewInputSession(lidClosed: true, screenAsleep: false)
        let ordinaryOffStatus = model.status
        var intent = LidSessionIntent(duration: .init(mode: .untilTurnedOff))
        intent.blocked = true
        try intent.save(defaults)
        XCTAssertFalse(model.enabled)
        XCTAssertEqual(model.status, ordinaryOffStatus, "A saved error must not replace the existing explicit Off status")

        model.enabled = true
        for reason in ["Mac is sleeping", "Paused while your Mac cools down",
                       "Quit another controller to use Backlit", "Paused with your display"] {
            model.pausedReason = reason
            XCTAssertEqual(model.status, reason, "Current pauses take priority over a saved error")
        }
        model.pausedReason = nil
        XCTAssertEqual(model.status, LidSavedPause.unconfirmedStatus)
        XCTAssertEqual(LidSessionIntent.load(defaults), intent)
    }

    @MainActor func testClosedLidWithoutErrorLatchKeepsOrdinaryStatusAndPreviewStaysExplicit() throws {
        let suite = "Backlit.LidPauseStatus." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var intent = LidSessionIntent(duration: .init(mode: .untilTurnedOff))
        try intent.save(defaults)
        let model = AppModel(demo: true, defaults: defaults, hardwareApply: { _, _ in
            XCTFail("Reading status must not apply hardware")
            return .applied
        })
        model.setPreviewInputSession(lidClosed: true, screenAsleep: true)
        model.pausedReason = "Paused with your display"
        XCTAssertEqual(model.status, "Paused with your display")
        defaults.removeObject(forKey: LidSessionIntent.preferenceKey)
        XCTAssertEqual(model.status, "Paused with your display")

        intent.blocked = true
        try intent.save(defaults)
        let preview = AppModel(demo: true, defaults: defaults)
        preview.setPreviewInputSession(lidClosed: true, screenAsleep: false)
        XCTAssertEqual(preview.status, "Preview · logo unchanged")
        XCTAssertEqual(LidSessionIntent.load(defaults), intent)
    }

}
