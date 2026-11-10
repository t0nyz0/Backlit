import XCTest
@testable import Backlit
final class LogoMappingOwnershipTests: XCTestCase {
    let previous:[[Double]]=[[0,0],[1000,0]]
    let intended:[[Double]]=[[0,1000],[1000,1000]]
    func testMappingSuccessThenWakeFailureRemainsOwnedForRestore() {
        XCTAssertTrue(LogoDevice.matchesOwnedMapping(intended,confirmed:previous,pending:intended))
    }
    func testRejectedMappingRetainsPriorOwnershipForRestore() {
        XCTAssertTrue(LogoDevice.matchesOwnedMapping(previous,confirmed:previous,pending:intended))
    }
    func testCompetingMappingAndUnknownReadbackAreNotOwned() {
        XCTAssertFalse(LogoDevice.matchesOwnedMapping([[0,42],[1000,42]],confirmed:previous,pending:intended))
        XCTAssertFalse(LogoDevice.matchesOwnedMapping(nil,confirmed:previous,pending:intended))
    }
    func testPartialRestoreCanBeRetriedWithoutMistakingOriginalForCompetitor() {
        XCTAssertTrue(LogoDevice.matchesOwnedMapping(previous,confirmed:intended,pending:previous))
    }
}
