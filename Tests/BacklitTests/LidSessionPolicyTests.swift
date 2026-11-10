import XCTest
@testable import Backlit
final class LidSessionPolicyTests: XCTestCase {
    func testUntilTurnedOffHasNoTimer() {
        XCTAssertFalse(LidSessionPolicy.timedOut(closedAt: 0, now: 10_000_000, duration: 0))
    }
    func testExactTimerBoundary() {
        XCTAssertFalse(LidSessionPolicy.timedOut(closedAt: 100, now: 1899.9, duration: 1800))
        XCTAssertTrue(LidSessionPolicy.timedOut(closedAt: 100, now: 1900, duration: 1800))
        XCTAssertFalse(LidSessionPolicy.timedOut(closedAt: nil, now: 1900, duration: 1800))
    }
    func testHoursAndMinutesShareSecondsBoundary() {
        XCTAssertTrue(LidSessionPolicy.timedOut(closedAt: 10, now: 7210, duration: 7200))
        XCTAssertFalse(LidSessionPolicy.timedOut(closedAt: 10, now: 70, duration: 120))
    }
    func testDurationValidationRejectsMalformedValues() {
        for value in [Double.nan, .infinity, -.infinity, -1, 604801] {
            XCTAssertFalse(LidSessionPolicy.validDuration(value))
        }
        for value in [0.0, 60, 1800, 604800] { XCTAssertTrue(LidSessionPolicy.validDuration(value)) }
    }
    func testUnlimitedStillStopsAtAllSafetyGates() {
        XCTAssertFalse(LidSessionPolicy.eligible(exhausted: false, externalPower: false, battery: 0.2, lowPower: false, thermal: .nominal))
        XCTAssertFalse(LidSessionPolicy.eligible(exhausted: false, externalPower: true, battery: 1, lowPower: true, thermal: .nominal))
        for thermal in [ProcessInfo.ThermalState.serious, .critical] {
            XCTAssertFalse(LidSessionPolicy.eligible(exhausted: false, externalPower: true, battery: 1, lowPower: false, thermal: thermal))
        }
        XCTAssertFalse(LidSessionPolicy.eligible(exhausted: true, externalPower: true, battery: 1, lowPower: false, thermal: .nominal))
        XCTAssertTrue(LidSessionPolicy.eligible(exhausted: false, externalPower: false, battery: 0.21, lowPower: false, thermal: .fair))
    }
}
