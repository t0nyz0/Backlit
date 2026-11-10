import XCTest
@testable import Backlit

final class AutomationTests:XCTestCase {
    private func command(_ value:String) throws ->AutomationCommand {
        try AutomationCommand(url:XCTUnwrap(URL(string:value)))
    }
    func testLinksUseTypedCommandsAndTrackpadAlias() throws {
        XCTAssertEqual(try command("backlit://toggle"),.toggle)
        XCTAssertEqual(try command("backlit://power?state=off"),.power(false))
        XCTAssertEqual(try command("backlit://brightness?value=37.5"),.brightness(0.375))
        XCTAssertEqual(try command("backlit://mode?name=Trackpad"),.mode(.touch))
    }
    func testLinksRejectCredentialsDuplicatesExtraPathsAndUnknownFields() {
        let invalid=["https://toggle","backlit://person@toggle","backlit://toggle:80", "backlit://toggle/anything",
                     "backlit://toggle#fragment","backlit://power?state=on&state=off", "backlit://toggle?token=secret",
                     "backlit://brightness?value=50&value=60","backlit://mode?name=unknown","backlit://mode?name",
                     "backlit://signal?category=build&state=active&message=arbitrary", "backlit://%74oggle",
                     "backlit://signal?category=focus&state=active", "backlit://mode?name=Signals", "backlit://focus"]
        for value in invalid {XCTAssertThrowsError(try command(value),value)}
    }
    func testBrightnessRejectsNonfiniteAndOutOfRangeValues() {
        for value in ["NaN","Infinity","-1","100.01","%2050","true"] {
            XCTAssertThrowsError(try command("backlit://brightness?value="+value),value)
        }
    }
    @MainActor func testRouterRequiresOptInAndValidatesBeforeCallingHandler() throws {
        let router=AutomationRouter();var calls=0
        router.handler={_ in calls+=1}
        XCTAssertThrowsError(try router.perform(.toggle));XCTAssertEqual(calls,0)
        router.enabled=true
        XCTAssertThrowsError(try router.perform(.brightness(.infinity)));XCTAssertEqual(calls,0)
        try router.perform(.toggle);XCTAssertEqual(calls,1)
        router.enabled=false
        XCTAssertThrowsError(try router.perform(.toggle));XCTAssertEqual(calls,1)
    }
}
