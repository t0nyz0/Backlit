import XCTest
@testable import Backlit

final class BacklitTests: XCTestCase {
    final class ValueTouchIdentity: NSObject {
        let value:Int
        init(_ value:Int){self.value=value}
        override var hash:Int {value.hashValue}
        override func isEqual(_ object:Any?)->Bool {(object as? ValueTouchIdentity)?.value == value}
    }
    func testEqualTouchIdentityObjectsReleaseAndCancelTheSameContact() {
        var contacts=TouchContacts()
        let first=ValueTouchIdentity(7), ended=ValueTouchIdentity(7)
        XCTAssertFalse(first === ended)
        contacts.update(identity:AnyHashable(first),phase:.began)
        contacts.update(identity:AnyHashable(ended),phase:.ended)
        XCTAssertTrue(contacts.active.isEmpty)
        contacts.update(identity:AnyHashable(first),phase:.began)
        contacts.update(identity:AnyHashable(ValueTouchIdentity(7)),phase:.cancelled)
        XCTAssertTrue(contacts.active.isEmpty)
        contacts.update(identity:AnyHashable(first),phase:.began)
        contacts.reset()
        XCTAssertTrue(contacts.active.isEmpty)
    }
    func testTouchTracksMultipleContactsAndHoldWithoutAClock() {
        var contacts=TouchContacts()
        contacts.update(identity:"first",phase:.began)
        contacts.update(identity:"second",phase:.began)
        contacts.update(identity:"first",phase:.ended)
        XCTAssertEqual(contacts.active.count,1)
        var input=EffectInput();input.mode = .touch;input.touchDown = !contacts.active.isEmpty
        XCTAssertEqual(Effects.level(at:10000,input:input),input.brightness)
        contacts.update(identity:"second",phase:.cancelled)
        input.touchDown = !contacts.active.isEmpty
        XCTAssertEqual(Effects.level(at:10001,input:input),0)
        XCTAssertEqual(Effects.level(at:10002,input:input),0)
    }
    func testDeviceLeaseRejectsConcurrentOwnershipAndReleases() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("lease")
        var first:FileLease?=try FileLease(url:file)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try FileLease(url:file))
        first=nil
        XCTAssertNoThrow(try FileLease(url:file))
    }
    @MainActor func testLoadingPreferencesPreservesSavedBrightnessAndPace() {
        let suite="local.backlit.test."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        defaults.set("breathe",forKey:"mode");defaults.set(0.93,forKey:"brightness")
        defaults.set(3.2,forKey:"period");defaults.set("dark",forKey:"appearance")
        defaults.set(false,forKey:"enabled")
        let model=AppModel(demo:true,defaults:defaults)
        XCTAssertEqual(model.mode,.breathe);XCTAssertEqual(model.brightness,0.93)
        XCTAssertEqual(model.period,3.2);XCTAssertFalse(model.enabled)
        XCTAssertEqual(defaults.double(forKey:"brightness"),0.93)
        XCTAssertEqual(defaults.double(forKey:"period"),3.2)
        XCTAssertEqual(defaults.string(forKey:"appearance"),"dark")
        model.mode = .steady
        XCTAssertEqual(defaults.double(forKey:"brightness"),0.93)
    }
    func testNativeContactsFilterHoverAndTrackDevicesSeparately() {
        var ledger=NativeContactLedger()
        ledger.update(device:1,path:7,state:2);XCTAssertEqual(ledger.count,0)
        ledger.update(device:1,path:7,state:3);ledger.update(device:1,path:7,state:4)
        ledger.update(device:2,path:7,state:4);XCTAssertEqual(ledger.count,2)
        ledger.update(device:1,path:7,state:5);XCTAssertEqual(ledger.count,1)
        ledger.update(device:2,path:7,state:7);XCTAssertEqual(ledger.count,0)
        ledger.update(device:2,path:9,state:3);ledger.reset();XCTAssertEqual(ledger.count,0)
        XCTAssertTrue(TouchSource.both.includes(.screen));XCTAssertTrue(TouchSource.both.includes(.trackpad))
        XCTAssertFalse(TouchSource.screen.includes(.trackpad))
    }
    func testAudioEnvelopeRespondsToBassAndResetsWithoutRecording() {
        let meter=AudioEnergyMeter()
        let frames=(0..<2048).map{Float(sin(2*Double.pi*80*Double($0)/48000)*0.03)}
        frames.withUnsafeBytes{meter.consume($0.baseAddress!,bytes:$0.count,channels:1,sampleRate:48000,bits:32)}
        XCTAssertGreaterThan(meter.level,0.1);XCTAssertLessThanOrEqual(meter.level,1)
        meter.reset();XCTAssertEqual(meter.level,0)
        [Float.nan,Float.infinity].withUnsafeBytes{meter.consume($0.baseAddress!,bytes:$0.count,channels:1,sampleRate:48000,bits:32)}
        XCTAssertEqual(meter.level,0)
        let friendly=SystemAudio.friendly(NSError(domain:"SCStreamErrorDomain",code:-3801))
        XCTAssertTrue(friendly.localizedDescription.contains("Privacy & Security"))
        XCTAssertFalse(friendly.localizedDescription.contains("TCC"))
    }
    func testAdvertisedEffectNamesRoundTripThroughTheAPI() throws {
        for mode in GlowMode.allCases {
            let data=try JSONSerialization.data(withJSONObject:["effect":mode.title])
            XCTAssertEqual(try LightCommand(data:data).mode,mode)
        }
    }
    func testAgentConfigurationLocationsUseDocumentedOverrides() {
        let home=URL(fileURLWithPath:"/tmp/fixture-home",isDirectory:true)
        XCTAssertEqual(CodingAgent.claude.configurationDirectory(environment:[:],home:home).lastPathComponent,".claude")
        XCTAssertEqual(CodingAgent.codex.configurationDirectory(environment:["CODEX_HOME":"/tmp/custom-codex"],home:home).path,"/tmp/custom-codex")
        XCTAssertEqual(CodingAgent.claude.configurationDirectory(environment:["CLAUDE_CONFIG_DIR":"relative"],home:home).lastPathComponent,".claude")
    }
    func testLegacyBacklitHookMigrationPreservesOtherCommands() throws {
        let legacy="/usr/bin/pgrep -xq Backlit || exit 0; '/old/Backlit' --backlit-hook claude working $sid"
        let original=try JSONSerialization.data(withJSONObject:["hooks":["Stop":[["hooks":[["type":"command","command":legacy],["type":"command","command":"echo user-hook"]]]]]])
        let removed=try AgentBridge.merged(original,agent:.claude,enabled:false,binary:"/new/Backlit",priorBinaries:["/old/Backlit"])
        let text=String(decoding:removed,as:UTF8.self)
        XCTAssertFalse(text.contains("/old/Backlit"));XCTAssertTrue(text.contains("echo user-hook"))
        XCTAssertThrowsError(try AgentBridge.receive(agent:.claude,state:"working",session:"invalid session"))
    }
    func testShellQuotingPreservesLiteralPathCharacters() throws {
        let value="folder with 'quotes' and $dollars"
        let process=Process(),output=Pipe()
        process.executableURL=URL(fileURLWithPath:"/bin/sh")
        process.arguments=["-c","printf '%s' "+AgentBridge.shellArgument(value)]
        process.standardOutput=output
        try process.run();process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus,0)
        XCTAssertEqual(String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self),value)
    }
    func testOffAlwaysWinsAcrossModes() {
        for mode in GlowMode.allCases {
            var input=EffectInput();input.mode=mode;input.enabled=false;input.audio=1;input.agent = .attention;input.away=true
            for t in stride(from:0.0,through:20,by:0.17) {XCTAssertEqual(Effects.level(at:t,input:input),0)}
        }
    }
    func testEffectsRemainFiniteAndBounded() {
        for mode in GlowMode.allCases {
            for brightness in [-1.0,0,0.6,1,3,Double.nan,Double.infinity] {
                var input=EffectInput();input.mode=mode;input.brightness=brightness;input.audio=0.8;input.away=true;input.agent = .attention
                for t in stride(from:0.0,through:12,by:0.07) {let level=Effects.level(at:t,input:input);XCTAssertTrue(level.isFinite && (0...1).contains(level))}
            }
        }
    }
    func testBatteryScalesWithoutExceedingChosenBrightness() {
        var input=EffectInput();input.mode = .battery;input.brightness=0.6;input.battery=0.5
        XCTAssertEqual(Effects.level(at:0,input:input),0.3,accuracy:0.0001)
        input.battery=2;XCTAssertEqual(Effects.level(at:0,input:input),0.6)
    }
    func testExplicitBreathingCycleVariesAtEveryPace() {
        var input=EffectInput();input.mode = .breathe;input.period=6;input.brightness=0.8
        XCTAssertLessThan(Effects.level(at:0,input:input),0.05)
        XCTAssertGreaterThan(Effects.level(at:3,input:input),0.75)
        XCTAssertEqual(Effects.level(at:0,input:input),Effects.level(at:6,input:input),accuracy:0.001)
        for period in [3.0,4.5,6,10] {
            input.period=period
            XCTAssertGreaterThan(Effects.level(at:period/2,input:input)-Effects.level(at:0,input:input),0.7)
        }
    }
    func testAttentionOnlyDoubleBlinksWhenAway() {
        var input=EffectInput();input.mode = .agents;input.agent = .attention;input.away=true
        XCTAssertGreaterThan(Effects.level(at:0.05,input:input),Effects.level(at:0.2,input:input))
        XCTAssertGreaterThan(Effects.level(at:0.33,input:input),Effects.level(at:0.5,input:input))
        input.away=false;XCTAssertEqual(Effects.level(at:0.05,input:input),Effects.level(at:0.2,input:input))
    }
    func testAgentHookTransactionsPreserveUnrelatedConfiguration() throws {
        let source=Data(#"{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"matcher":"custom","hooks":[{"type":"command","command":"echo existing"}]}],"CustomFutureEvent":[{"hooks":[{"type":"command","command":"future"}]}]}}"#.utf8)
        for agent in CodingAgent.allCases {
            let once=try AgentBridge.merged(source,agent:agent,enabled:true,binary:"/tmp/My App's/Backlit")
            let twice=try AgentBridge.merged(once,agent:agent,enabled:true,binary:"/tmp/My App's/Backlit")
            XCTAssertEqual(once,twice)
            let removed=try AgentBridge.merged(twice,agent:agent,enabled:false,binary:"/tmp/My App's/Backlit")
            let before=try JSONSerialization.jsonObject(with:source) as! NSDictionary
            let after=try JSONSerialization.jsonObject(with:removed) as! NSDictionary
            XCTAssertEqual(before,after)
        }
    }
    func testMalformedHookFormatIsNotOverwritten() {
        for text in ["[]",#"{"hooks":"wrong"}"#,#"{"hooks":{"Stop":[{"hooks":"wrong"}]}}"#] {
            XCTAssertThrowsError(try AgentBridge.merged(Data(text.utf8),agent:.claude,enabled:true,binary:"/tmp/Backlit"))
        }
    }
    func testAgentIngressPersistsOnlyMetadataAndExpiresStaleEvents() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        try AgentBridge.receive(agent:.codex,state:"working",session:"session-A",directory:directory)
        try AgentBridge.receive(agent:.claude,state:"attention",session:"session-B",directory:directory)
        let events=AgentBridge.events(directory:directory)
        XCTAssertEqual(events.count,2);XCTAssertEqual(AgentBridge.aggregate(events),.attention)
        let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
        let payload=try JSONSerialization.jsonObject(with:Data(contentsOf:files[0])) as! [String:Any]
        XCTAssertEqual(Set(payload.keys),["agent","state","time"])
        XCTAssertTrue(AgentBridge.events(directory:directory,now:Date().addingTimeInterval(1000)).isEmpty)
        try AgentBridge.receive(agent:.codex,state:"ended",session:"session-A",directory:directory)
        XCTAssertEqual(AgentBridge.events(directory:directory).count,1)
    }
    func testHTTPFramingAndAuthorization() throws {
        let bytes=Data("GET /v1/state HTTP/1.1\r\nAuthorization: Bearer example\r\n\r\n".utf8)
        XCTAssertNil(try BridgeRequest.parse(bytes.prefix(20)))
        let request=try XCTUnwrap(BridgeRequest.parse(bytes))
        XCTAssertTrue(request.authorized("example"));XCTAssertFalse(request.authorized("wrong"))
        XCTAssertThrowsError(try BridgeRequest.parse(Data("GET /v1/state HTTP/1.1\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n".utf8)))
        let origin=try XCTUnwrap(BridgeRequest.parse(Data("GET /v1/state HTTP/1.1\r\nAuthorization: Bearer example\r\nOrigin: https://example.com\r\n\r\n".utf8)))
        XCTAssertFalse(origin.authorized("example"))
        XCTAssertThrowsError(try BridgeRequest.parse(Data("POST /v1/light HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try BridgeRequest.parse(Data(repeating:65,count:16385)))
    }
    func testLightCommandsValidateBeforeMutation() throws {
        let command=try LightCommand(data:Data(#"{"enabled":false,"brightness":127.5,"effect":"Breathe"}"#.utf8))
        XCTAssertEqual(command.enabled,false);XCTAssertEqual(command.brightness,0.5);XCTAssertEqual(command.mode,.breathe)
        for raw in [#"{"enabled":"yes"}"#,#"{"enabled":1}"#,#"{"brightness":true}"#,#"{"brightness":256}"#,#"{"brightness":-1}"#,#"{"effect":"RGB"}"#,#"{"token":"x"}"#,"{}"] {
            XCTAssertThrowsError(try LightCommand(data:Data(raw.utf8)))
        }
    }
    func testRecoveryMappingValidationAndComparison() {
        XCTAssertFalse(LogoDevice.valid([[0,Double.nan],[1,2]]))
        XCTAssertFalse(LogoDevice.valid([[0],[1,2]]))
        XCTAssertFalse(LogoDevice.equivalent([[0,1],[5,2]],[[0,1],[5,3]]))
        XCTAssertTrue(LogoDevice.equivalent([[0,1],[5,2]],[[0,1.00000001],[5,2]]))
    }
    @MainActor func testLocalBridgeEndToEnd() async throws {
        let server=HomeBridge();defer{server.stop()}
        let ready=expectation(description:"listener ready")
        server.onStatus={if $0.contains("Available") {ready.fulfill()}}
        var enabled=true
        server.state={ ["id":"integration-test","controlling":true,"enabled":enabled] }
        server.command={if let value=$0.enabled {enabled=value}}
        try server.start(lan:false,token:"ephemeral-test-key",port:0)
        await fulfillment(of:[ready],timeout:5)
        let port=try XCTUnwrap(server.port)
        let url=URL(string:"http://127.0.0.1:\(port)/v1/light")!
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=Data(#"{"enabled":false}"#.utf8)
        let (_,denied)=try await URLSession.shared.data(for:request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode,401);XCTAssertTrue(enabled)
        request.setValue("Bearer ephemeral-test-key",forHTTPHeaderField:"Authorization")
        let (data,response)=try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        XCTAssertFalse(enabled)
        let state=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        XCTAssertEqual(state["enabled"] as? Bool,false)
    }
}
