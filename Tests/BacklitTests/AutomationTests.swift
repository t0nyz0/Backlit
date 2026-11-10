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
        XCTAssertEqual(try command("backlit://signal?category=export&state=active&duration=120&progress=0.5"),
                       .signal(try ActivitySignal(category:.export,state:.active,duration:120,progress:0.5)))
    }
    func testLinksRejectCredentialsDuplicatesExtraPathsAndUnknownFields() {
        let invalid=["https://toggle","backlit://person@toggle","backlit://toggle:80", "backlit://toggle/anything",
                     "backlit://toggle#fragment","backlit://power?state=on&state=off", "backlit://toggle?token=secret",
                     "backlit://brightness?value=50&value=60","backlit://mode?name=unknown","backlit://mode?name",
                     "backlit://signal?category=build&state=active&message=arbitrary", "backlit://%74oggle"]
        for value in invalid {XCTAssertThrowsError(try command(value),value)}
    }
    func testBrightnessRejectsNonfiniteAndOutOfRangeValues() {
        for value in ["NaN","Infinity","-1","100.01","%2050","true"] {
            XCTAssertThrowsError(try command("backlit://brightness?value="+value),value)
        }
    }
    func testSignalValidationBoundsLifetimeAndProgress() throws {
        XCTAssertEqual(try ActivitySignal(category:.build,state:.active).effectiveDuration,60)
        XCTAssertEqual(try ActivitySignal(category:.build,state:.complete).effectiveDuration,8)
        XCTAssertEqual(try ActivitySignal(category:.build,state:.clear).effectiveDuration,0)
        XCTAssertNoThrow(try ActivitySignal(category:.focus,state:.active,duration:14_400,progress:0))
        XCTAssertThrowsError(try ActivitySignal(category:.focus,state:.active,duration:14_401))
        XCTAssertThrowsError(try ActivitySignal(category:.backup,state:.complete,duration:61))
        XCTAssertThrowsError(try ActivitySignal(category:.backup,state:.active,progress:1.01))
        XCTAssertThrowsError(try ActivitySignal(category:.backup,state:.complete,progress:1))
        XCTAssertThrowsError(try ActivitySignal(category:.recording,state:.clear,duration:1))
        XCTAssertThrowsError(try ActivitySignal(category:.recording,state:.active,duration:.nan))
    }
    func testHTTPMetadataRejectsBooleansUnknownKeysAndArbitraryContent() throws {
        let valid=Data(#"{"category":"backup","state":"active","progress":0.2}"#.utf8)
        XCTAssertEqual(try ActivitySignal(data:valid),try ActivitySignal(category:.backup,state:.active,progress:0.2))
        for text in [#"{"category":"build","state":"active","duration":true}"#,
                     #"{"category":"build","state":"active","progress":"0.2"}"#,
                     #"{"category":"build","state":"active","path":"private"}"#,
                     #"{"category":"unknown","state":"active"}"#,
                     #"{"category":"build","state":"unknown"}"#] {
            XCTAssertThrowsError(try ActivitySignal(data:Data(text.utf8)))
        }
    }
    func testDecodedSignalsCannotBypassValidation() {
        let bad=Data(#"{"category":"build","state":"clear","duration":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ActivitySignal.self,from:bad))
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
