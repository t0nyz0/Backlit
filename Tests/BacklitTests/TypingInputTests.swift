import XCTest
@testable import Backlit

final class TypingInputTests:XCTestCase {
    func testBurstStartsOnceAndExpiresOnlyAfterItsDeadline() {
        var timing=TypingActivity(holdDuration:0.2)
        XCTAssertFalse(timing.active)
        XCTAssertTrue(timing.keyDown(at:10))
        XCTAssertFalse(timing.keyDown(at:10.1))
        XCTAssertFalse(timing.expire(at:10.2))
        XCTAssertTrue(timing.active)
        XCTAssertEqual(timing.deadline!,10.3,accuracy:0.0001)
        XCTAssertTrue(timing.expire(at:10.31))
        XCTAssertFalse(timing.active)
        XCTAssertNil(timing.deadline)
        XCTAssertFalse(timing.expire(at:11))
    }
    func testResetClearsBurstAndAcceptsANewClockSession() {
        var timing=TypingActivity()
        XCTAssertTrue(timing.keyDown(at:100))
        XCTAssertTrue(timing.reset())
        XCTAssertNil(timing.deadline)
        XCTAssertFalse(timing.active)
        XCTAssertFalse(timing.reset())
        XCTAssertFalse(timing.expire(at:101))
        XCTAssertTrue(timing.keyDown(at:1))
    }
    func testInvalidOrOutOfOrderTimingCannotExtendTheBurst() {
        var timing=TypingActivity(holdDuration:0.2)
        XCTAssertFalse(timing.keyDown(at:.nan))
        XCTAssertFalse(timing.keyDown(at:.infinity))
        XCTAssertFalse(timing.keyDown(at:-1))
        XCTAssertNil(timing.deadline)
        XCTAssertTrue(timing.keyDown(at:5))
        let deadline=timing.deadline
        XCTAssertFalse(timing.keyDown(at:4))
        XCTAssertFalse(timing.keyDown(at:.infinity))
        XCTAssertEqual(timing.deadline,deadline)
        XCTAssertFalse(timing.expire(at:.infinity))
        XCTAssertTrue(timing.expire(at:5.21))
    }
    func testInactivityWindowIsFiniteAndBounded() {
        var timing=TypingActivity(holdDuration:-10)
        XCTAssertEqual(timing.holdDuration,0.08)
        timing.holdDuration=100
        XCTAssertEqual(timing.holdDuration,0.6)
        timing.holdDuration = .nan
        XCTAssertEqual(timing.holdDuration,TypingActivity.defaultHoldDuration)
        XCTAssertTrue(timing.keyDown(at:0))
        XCTAssertEqual(timing.deadline!,TypingActivity.defaultHoldDuration,accuracy:0.0001)
    }
}
