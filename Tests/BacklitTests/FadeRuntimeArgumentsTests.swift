import XCTest
import Darwin
@testable import Backlit
final class FadeRuntimeArgumentsTests:XCTestCase {
    func testStrictHelperArguments() {
        let token=UUID()
        let valid=["Backlit","--watch-fade",token.uuidString,"123","456","789"]
        XCTAssertEqual(FadeHelperArguments(valid)?.token,token)
        for args in [Array(valid.dropLast()),valid+["extra"],["Backlit","--watch-fade",token.uuidString,"0","456","0"],["Backlit","--watch-fade",token.uuidString,"123","456","1000000"]] {
            XCTAssertNil(FadeHelperArguments(args))
        }
    }
    func testProcessIdentityIncludesStartTimeNotJustPID() throws {
        let current=try XCTUnwrap(FadeProcessIdentity.read(getpid()))
        XCTAssertTrue(current.isAlive)
        XCTAssertFalse(FadeProcessIdentity(pid:current.pid,seconds:current.seconds+1,microseconds:current.microseconds).isAlive)
        XCTAssertNil(FadeProcessIdentity.read(-1))
    }
}
