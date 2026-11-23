#if BACKLIT_CONTROL_CENTER
import XCTest
@testable import Backlit

final class ControlCenterStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000)
    func testRequestedAndEffectiveAreNotConflated() throws {
        for effective in [false, true] {
            let sample = BacklitControlSnapshot(requestedEnabled: true, effectiveOutput: effective, available: true, observedAt: now)
            let result = try BacklitControlState.decode(JSONEncoder().encode(sample), now: now)
            XCTAssertTrue(result.requestedEnabled)
            XCTAssertEqual(result.effectiveOutput, effective)
        }
    }
    func testMissingMalformedOversizedStaleFutureUnknownAndUnavailableAreNotOff() throws {
        for data in [Data(), Data("{}".utf8), Data(repeating: 0, count: 4097)] {
            XCTAssertThrowsError(try BacklitControlState.decode(data, now: now))
        }
        for sample in [
            BacklitControlSnapshot(schemaVersion: 2, requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now),
            .init(requestedEnabled: false, effectiveOutput: false, available: false, observedAt: now),
            .init(requestedEnabled: false, effectiveOutput: true, available: true, observedAt: now),
            .init(requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now.addingTimeInterval(-61)),
            .init(requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now.addingTimeInterval(1))
        ] { XCTAssertThrowsError(try BacklitControlState.decode(JSONEncoder().encode(sample), now: now)) }
        let validOff = BacklitControlSnapshot(requestedEnabled: false, effectiveOutput: false, available: true, observedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(try BacklitControlState.decode(JSONEncoder().encode(validOff), now: now).requestedEnabled)
    }
    @MainActor func testExtensionWithoutHostHandlerCannotPerformPower() throws {
        BacklitControlBridge.setPower = nil
        XCTAssertThrowsError(try BacklitControlBridge.perform(true))
        XCTAssertThrowsError(try BacklitControlBridge.perform(false))
        var values: [Bool] = []
        BacklitControlBridge.setPower = { values.append($0) }
        defer { BacklitControlBridge.setPower = nil }
        try BacklitControlBridge.perform(false)
        XCTAssertEqual(values, [false])
    }
}
#endif
