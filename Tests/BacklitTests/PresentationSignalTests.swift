import XCTest
@testable import Backlit

final class PresentationSignalTests: XCTestCase {
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

    func testSignalExpiryDoesNotReportSuccessfulBuild() throws {
        var engine = ActivitySignalEngine()
        engine.submit(try ActivitySignal(category: .build, state: .active, duration: 10, progress: 0.5), at: 0)
        XCTAssertGreaterThan(engine.level(at: 1), 0)
        XCTAssertEqual(engine.level(at: 10), 0)
        XCTAssertNil(engine.current)
    }

    func testFocusDeadlineCompletesAndOtherSignalsResume() throws {
        var engine = ActivitySignalEngine()
        engine.submit(try ActivitySignal(category: .recording, state: .active, duration: 60, progress: nil), at: 0)
        engine.submit(try ActivitySignal(category: .focus, state: .active, duration: 10, progress: nil), at: 0)
        _ = engine.level(at: 5)
        XCTAssertEqual(engine.current?.category, .recording)
        _ = engine.level(at: 10)
        XCTAssertEqual(engine.current?.state, .complete)
        XCTAssertEqual(engine.current?.category, .focus)
        _ = engine.level(at: 18)
        XCTAssertEqual(engine.current?.category, .recording)
    }

    func testSignalAttentionPriorityAndExplicitClear() throws {
        var engine = ActivitySignalEngine()
        engine.submit(try ActivitySignal(category: .backup, state: .attention, duration: 8, progress: nil), at: 0)
        engine.submit(try ActivitySignal(category: .build, state: .active, duration: 60, progress: nil), at: 1)
        _ = engine.level(at: 1)
        XCTAssertEqual(engine.current?.category, .backup)
        engine.submit(try ActivitySignal(category: .backup, state: .clear, duration: nil, progress: nil), at: 2)
        _ = engine.level(at: 2)
        XCTAssertEqual(engine.current?.category, .build)
        XCTAssertEqual(engine.level(at: .nan), 0)
        XCTAssertEqual(engine.count, 0)
    }
}
