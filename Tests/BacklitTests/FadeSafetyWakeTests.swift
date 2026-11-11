import XCTest
@testable import Backlit
final class FadeSafetyWakeTests:XCTestCase {
    func testSignalBeforeWaitRemainsConsumableAndCoalesces() throws {
        let wake=try FadeSafetyWake();wake.signal();wake.signal()
        XCTAssertTrue(wake.wait(0.2));XCTAssertFalse(wake.wait(0.01))
    }
    func testCrossThreadSignalWakesWaitingLoop() throws {
        let wake=try FadeSafetyWake()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.02){wake.signal()}
        XCTAssertTrue(wake.wait(1))
    }
    func testMissingSourceFailsInsteadOfPollingHotLoop() {
        XCTAssertThrowsError(try FadeSafetyWake(sourceFactory:{nil}))
    }
    func testTimeoutDoesNotBusySpin() throws {
        let wake=try FadeSafetyWake(),start=ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(wake.wait(0.02))
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime-start,0.01)
    }
    func testConcurrentSignalAndTeardownRemainSafe() throws {
        let wake=try FadeSafetyWake(),group=DispatchGroup()
        group.enter();DispatchQueue.global().async {for _ in 0..<200 {wake.signal()};group.leave()}
        wake.invalidate();group.wait();wake.signal();XCTAssertFalse(wake.wait(0.02))
    }
}
