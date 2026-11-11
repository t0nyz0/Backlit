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

}
