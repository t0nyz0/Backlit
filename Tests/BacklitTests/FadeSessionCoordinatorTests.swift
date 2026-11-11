import XCTest
@testable import Backlit
final class FadeSessionCoordinatorTests:XCTestCase {
    final class Session:FadeEffectSession {
        var needsAnimation=true
        var writes=0, restores=0
        var result=FadeApplyResult.applied
        var failApply=false, failRestore=false
        var duringApply:(()->Void)?
        func apply(_ brightness:Double,closedLidRequested:Bool,frameInterval:Double)throws->FadeApplyResult {
            duringApply?()
            if failApply {throw RuntimeServices.failure("helper already recovered")}
            writes += 1;return result
        }
        func restore()throws {restores += 1;if failRestore {throw RuntimeServices.failure("missing or unverified receipt")}}
    }
    func testNormalCloseRetiresOnlySessionAndReopenCreatesFreshSession()throws {
        var lid=false,created=0;var sessions:[Session]=[]
        let owner=FadeSessionCoordinator(physicalLid:{lid},makeSession:{_ in created += 1;let s=Session();sessions.append(s);return s})
        XCTAssertEqual(try owner.apply(0.6,closedLidRequested:false,frameInterval:0.1),.applied)
        lid=true
        XCTAssertEqual(try owner.apply(0.6,closedLidRequested:false,frameInterval:0.1),.paused)
        XCTAssertEqual(sessions[0].writes,1);XCTAssertEqual(sessions[0].restores,1);XCTAssertFalse(owner.hasSession)
        XCTAssertEqual(try owner.apply(0.6,closedLidRequested:false,frameInterval:0.1),.paused);XCTAssertEqual(created,1)
        lid=false
        XCTAssertEqual(try owner.apply(0.6,closedLidRequested:false,frameInterval:0.1),.applied);XCTAssertEqual(created,2)
    }
    func testEnableWhileAlreadyClosedWaitsForNewGrant()throws {
        let s=Session();s.result = .waiting;var made:[Bool]=[]
        let owner=FadeSessionCoordinator(physicalLid:{true},makeSession:{made.append($0);return s})
        XCTAssertEqual(try owner.apply(1,closedLidRequested:false,frameInterval:0.1),.paused);XCTAssertTrue(made.isEmpty)
        XCTAssertEqual(try owner.apply(1,closedLidRequested:true,frameInterval:0.1),.waiting)
        XCTAssertEqual(made,[true]);s.result = .applied
        XCTAssertEqual(try owner.apply(1,closedLidRequested:true,frameInterval:0.1),.applied)
    }
    func testHelperFirstCloseRequiresVerifiedReceiptBeforePause()throws {
        var lid=false;let s=Session();s.failApply=true;s.duringApply={lid=true}
        let owner=FadeSessionCoordinator(physicalLid:{lid},makeSession:{_ in s})
        XCTAssertEqual(try owner.apply(1,closedLidRequested:false,frameInterval:0.1),.paused)
        XCTAssertEqual(s.restores,1);XCTAssertFalse(owner.hasSession)
    }
    func testFailedRecoveryRetainsSessionAndPreventsReplacement()throws {
        var lid=false,made=0;let s=Session()
        let owner=FadeSessionCoordinator(physicalLid:{lid},makeSession:{_ in made += 1;return s})
        _=try owner.apply(1,closedLidRequested:false,frameInterval:0.1)
        lid=true;s.failRestore=true
        XCTAssertThrowsError(try owner.apply(1,closedLidRequested:false,frameInterval:0.1))
        XCTAssertTrue(owner.hasSession);XCTAssertEqual(made,1);XCTAssertEqual(s.restores,1)
        // A policy change must not make this failed recovery disappear.
        lid=false
        XCTAssertThrowsError(try owner.apply(1,closedLidRequested:false,frameInterval:0.1));XCTAssertEqual(made,1)
    }
    func testUnknownLidAndUnexplainedFailureStayErrors() {
        let s=Session();var lid:Bool?=nil
        let owner=FadeSessionCoordinator(physicalLid:{lid},makeSession:{_ in s})
        XCTAssertThrowsError(try owner.apply(1,closedLidRequested:false,frameInterval:0.1));XCTAssertEqual(s.writes,0)
        lid=false;s.failApply=true
        XCTAssertThrowsError(try owner.apply(1,closedLidRequested:false,frameInterval:0.1));XCTAssertEqual(s.restores,0)
    }
}
