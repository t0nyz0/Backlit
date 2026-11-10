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

}
