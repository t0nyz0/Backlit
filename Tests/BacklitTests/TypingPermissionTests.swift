import XCTest
@testable import Backlit

@MainActor final class TypingPermissionTests: XCTestCase {
    func testDeniedRequestPreservesActionableMessageAndActualNativeResults() {
        var requests = 0, checks = 0
        let input = TypingInput(preflightAccess: { checks += 1; return false }, requestAccess: {
            requests += 1; return false
        })
        let check = input.requestPermissionCheck()
        XCTAssertEqual(check, .init(before: false, requestResult: false, after: false))
        XCTAssertEqual(checks, 2); XCTAssertEqual(requests, 1)
        XCTAssertTrue(input.status.contains("macOS still denies"))
        XCTAssertTrue(input.status.contains("Open Input Monitoring"))
        XCTAssertTrue(check.diagnostic.contains("access after = denied"))
        XCTAssertFalse(input.running)
    }

    func testRequestSuccessDoesNotClaimAccessWhenPreflightStillDenies() {
        let input = TypingInput(preflightAccess: { false }, requestAccess: { true })
        let check = input.requestPermissionCheck()
        XCTAssertEqual(check, .init(before: false, requestResult: true, after: false))
        XCTAssertTrue(input.status.contains("macOS still denies"))
        XCTAssertFalse(input.running)
    }

    func testAlreadyAllowedCheckDoesNotPromptOrStartAListener() {
        let input = TypingInput(preflightAccess: { true }, requestAccess: {
            XCTFail("Already allowed must not request again"); return false
        })
        let check = input.requestPermissionCheck()
        XCTAssertEqual(check, .init(before: true, requestResult: nil, after: true))
        XCTAssertEqual(input.status, "Typing access is allowed")
        XCTAssertFalse(input.running)
    }

    func testGrantIsReportedOnlyWhenPostRequestPreflightAllowsIt() {
        var allowed = false
        let input = TypingInput(preflightAccess: { allowed }, requestAccess: {
            allowed = true; return true
        })
        XCTAssertEqual(input.requestPermissionCheck(), .init(before: false, requestResult: true, after: true))
        XCTAssertFalse(input.running)
    }
}
