#if BACKLIT_CONTROL_CENTER
import XCTest
@testable import Backlit

final class ControlCenterStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000)
    func testRequestedAndEffectiveAreNotConflated() throws {
        for effective in [false, true] {
            let sample = LogoLightControlSnapshot(requestedEnabled: true, effectiveOutput: effective, available: true, observedAt: now)
            let result = try LogoLightControlState.decode(JSONEncoder().encode(sample), now: now)
            XCTAssertTrue(result.requestedEnabled)
            XCTAssertEqual(result.effectiveOutput, effective)
        }
    }
    func testMissingMalformedOversizedStaleFutureUnknownAndUnavailableAreNotOff() throws {
        for data in [Data(), Data("{}".utf8), Data(repeating: 0, count: 4097)] {
            XCTAssertThrowsError(try LogoLightControlState.decode(data, now: now))
        }
        for sample in [
            LogoLightControlSnapshot(schemaVersion: 2, requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now),
            .init(requestedEnabled: false, effectiveOutput: false, available: false, observedAt: now),
            .init(requestedEnabled: false, effectiveOutput: true, available: true, observedAt: now),
            .init(requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now.addingTimeInterval(-61)),
            .init(requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now.addingTimeInterval(1))
        ] { XCTAssertThrowsError(try LogoLightControlState.decode(JSONEncoder().encode(sample), now: now)) }
        let validOff = LogoLightControlSnapshot(requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(try LogoLightControlState.decode(JSONEncoder().encode(validOff), now: now).requestedEnabled)
    }
    @MainActor func testExtensionWithoutHostHandlerCannotPerformPower() throws {
        LogoLightControlBridge.setPower = nil
        XCTAssertThrowsError(try LogoLightControlBridge.perform(true))
        XCTAssertThrowsError(try LogoLightControlBridge.perform(false))
        var values: [Bool] = []
        LogoLightControlBridge.setPower = { values.append($0) }
        defer { LogoLightControlBridge.setPower = nil }
        try LogoLightControlBridge.perform(false)
        XCTAssertEqual(values, [false])
    }
}
#endif
