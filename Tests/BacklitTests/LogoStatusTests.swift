import XCTest
@testable import Backlit

final class LogoStatusTests: XCTestCase {
    func testClosedLidDisabledHardwareOverridesFullRequestedBrightness() {
        let state = LogoStatus(requested: 1, hardwareEnabled: false, controlling: true, lidClosed: true, preview: false)
        XCTAssertEqual(state.level, 0)
        XCTAssertEqual(state.detail, "Logo off · lid closed")
        XCTAssertEqual(StatusIconGeometry.step(for: state.level), 0)
    }
    func testOpenLidDisabledHardwareAlsoOverridesRequestedEffect() {
        let state = LogoStatus(requested: 0.8, hardwareEnabled: false, controlling: true, lidClosed: false, preview: false)
        XCTAssertEqual(state.level, 0)
        XCTAssertEqual(state.detail, "Logo off · hardware disabled")
    }
    func testClosedLidIsNotAssumedOffWhenHardwareRemainsEnabled() {
        let state = LogoStatus(requested: 0.6, hardwareEnabled: true, controlling: true, lidClosed: true, preview: false)
        XCTAssertEqual(state.level, 0.6)
        XCTAssertTrue(state.detail.contains("requested"))
    }
    func testUnknownHardwareDoesNotClaimIllumination() {
        let state = LogoStatus(requested: 1, hardwareEnabled: nil, controlling: true, lidClosed: false, preview: false)
        XCTAssertEqual(state.level, 0)
        XCTAssertTrue(state.detail.contains("unavailable"))
        XCTAssertTrue(state.detail.contains("100% requested"))
    }
    func testNoOwnershipDoesNotShowRequestedLevelAsActual() {
        let state = LogoStatus(requested: 1, hardwareEnabled: true, controlling: false, lidClosed: false, preview: false)
        XCTAssertEqual(state.level, 0)
        XCTAssertTrue(state.detail.contains("not controlling"))
    }
    func testPreviewStaysExplicitAndDoesNotUsePhysicalState() {
        let state = LogoStatus(requested: 0.4, hardwareEnabled: false, controlling: false, lidClosed: true, preview: true)
        XCTAssertEqual(state.level, 0.4)
        XCTAssertTrue(state.detail.hasPrefix("Preview"))
    }
    func testReopenAndRepeatedCloseReturnToCorrectStatusWithoutChangingRequestedLevel() {
        let states = [false, true, false, true].map {
            LogoStatus(requested: 0.75, hardwareEnabled: $0, controlling: true, lidClosed: !$0, preview: false)
        }
        XCTAssertEqual(states.map(\.level), [0, 0.75, 0, 0.75])
    }
}
