import XCTest
import Network
import MCP
@testable import Backlit

final class MCPTests: XCTestCase {
    static var state: AgentLightState {
        .init(access:.control,enabled:true,mode:"steady",manualBrightnessPercent:68,
              calculatedOutputPercent:68,hardwareEnabled:true,hardwareSampleAgeSeconds:0.2,
              hardwareSupported:true,controlling:true,preview:false,recoveryRequired:false,busy:false,paused:nil,
              applicationResult:"applied",observedAt:"2026-01-01T00:00:00Z",availableModes:[])
    }
    @MainActor private func start(_ server: HomeBridge, access: MCPAccess = .control,
                                  token: String = "fixture-agent") async throws -> UInt16 {
        let ready = expectation(description:"isolated listener ready")
        server.onStatus = { if $0.contains("Available") { ready.fulfill() } }
        try server.start(lan:false,token:"fixture-home",port:0,agentToken:token,agentAccess:access)
        await fulfillment(of:[ready],timeout:5)
        server.onStatus = nil
        let port = try XCTUnwrap(server.port)
        XCTAssertNotEqual(port,48261,"Never contact the installed app")
        return port
    }
    func testSchemasAndStrictArgumentValidation() throws {
        XCTAssertEqual(BacklitMCPTools.tools.count,4)
        XCTAssertTrue(BacklitMCPTools.tools.allSatisfy{$0.annotations.idempotentHint == true})
        XCTAssertEqual(BacklitMCPTools.tools.first?.annotations.readOnlyHint,true)
        let invalid: [(String,[String:Value])] = [
            ("backlit_get_status",["token":"secret"]),("backlit_set_power",["enabled":1]),
            ("backlit_set_power",[:]),("backlit_set_power",["enabled":true,"url":"https://example.com"]),
            ("backlit_set_brightness",["percent":true]),("backlit_set_brightness",["percent":"50"]),
            ("backlit_set_brightness",["percent":.double(.nan)]),("backlit_set_brightness",["percent":101]),
            ("backlit_set_mode",["mode":"Music"]),("backlit_set_mode",["mode":"shell"]),
            ("backlit_toggle",[:])
        ]
        for (name,args) in invalid {
            XCTAssertThrowsError(try BacklitMCPTools.command(name:name,arguments:args),name)
        }
        let value = try BacklitMCPTools.command(name:"backlit_set_brightness",arguments:["percent":37.5])
        XCTAssertEqual(value?["brightness"]?.doubleValue,95.625)
        XCTAssertEqual(try BacklitMCPTools.command(name:"backlit_set_mode",arguments:["mode":"trackpad"]),["effect":"touch"])
    }
    func testToolErrorKeepsAStableCodeAndInvalidArgumentsNeverCallBackend() async throws {
        let tools = BacklitMCPTools { _ in throw ExternalControlError(.recoveryRequired,"Restore the light locally.") }
        let result = await tools.call(.init(name:"backlit_get_status"))
        XCTAssertEqual(result.isError,true)
        XCTAssertEqual(result.structuredContent?.objectValue?["code"],"RECOVERY_REQUIRED")
        let invalid = await tools.call(.init(name:"backlit_set_power",arguments:["enabled":"yes"]))
        XCTAssertEqual(invalid.structuredContent?.objectValue?["code"],"INVALID_ARGUMENT")
    }
    func testSuccessHasStructuredAndMatchingTextContent() async throws {
        let tools = BacklitMCPTools { _ in Self.state }
        let result = await tools.call(.init(name:"backlit_get_status"))
        XCTAssertEqual(result.isError,false)
        guard case .text(let text,_,_) = result.content.first else { return XCTFail("Missing text fallback") }
        XCTAssertEqual(try JSONDecoder().decode(Value.self,from:Data(text.utf8)),result.structuredContent)
        XCTAssertEqual(result.structuredContent?.objectValue?["manual_brightness_percent"],68)
    }
    func testActualPartialStatusUsesDeclaredOutputPropertiesForEveryTool() async throws {
        for flag: Bool? in [nil, false, true] {
            var sample = Self.state; sample.agentScanLimited = flag
            let response = sample
            let backend = BacklitMCPTools { _ in response }
            for tool in BacklitMCPTools.tools {
                let arguments: [String: Value]
                switch tool.name {
                case "backlit_set_power": arguments = ["enabled": true]
                case "backlit_set_brightness": arguments = ["percent": 50]
                case "backlit_set_mode": arguments = ["mode": "steady"]
                default: arguments = [:]
                }
                let result = await backend.call(.init(name: tool.name, arguments: arguments))
                XCTAssertEqual(result.isError, false)
                let actual = try XCTUnwrap(result.structuredContent?.objectValue)
                let success = try XCTUnwrap(tool.outputSchema?.objectValue?["oneOf"]?.arrayValue?.first?.objectValue)
                let properties = try XCTUnwrap(success["properties"]?.objectValue)
                XCTAssertEqual(success["additionalProperties"], .bool(false))
                XCTAssertTrue(Set(actual.keys).isSubset(of: Set(properties.keys)), "Undeclared success properties: \(actual.keys)")
                for required in try XCTUnwrap(success["required"]?.arrayValue) {
                    XCTAssertNotNil(actual[try XCTUnwrap(required.stringValue)])
                }
                if let flag {
                    XCTAssertEqual(actual["agent_scan_limited"], .bool(flag))
                    XCTAssertEqual(properties["agent_scan_limited"]?.objectValue?["type"], .string("boolean"))
                } else { XCTAssertNil(actual["agent_scan_limited"]) }
            }
        }
    }
    @MainActor func testReadOnlyCredentialCannotWriteAndCannotAccessHomeAssistantRoutes() async throws {
        let server = HomeBridge(); defer { server.stop() }
        server.agentState = { Self.state }
        var writes = 0; server.agentCommand = { _ in writes += 1 }
        let port = try await start(server,access:.status)
        let client = MCPBridgeClient(port:port,token:{"fixture-agent"})
        let state = try await client.request(nil)
        XCTAssertEqual(state.mode,"steady")
        do { _ = try await client.request(["enabled":false]); XCTFail("Read-only write accepted") }
        catch { XCTAssertEqual((error as? ExternalControlError)?.code,.accessDisabled) }
        for (key,path) in [("fixture-agent","state"),("fixture-home","agent/state")] {
            var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/\(path)")!)
            request.setValue("Bearer " + key,forHTTPHeaderField:"Authorization")
            let (_,response) = try await URLSession.shared.data(for:request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,401)
        }
        XCTAssertEqual(writes,0)
    }
    @MainActor func testSDKClientRoundTripReachesAuthenticatedBridgeAndReportsModeAndPower() async throws {
        let bridge = HomeBridge(); defer { bridge.stop() }
        var lastCommand: LightCommand?
        bridge.agentState = { Self.state }
        bridge.agentCommand = { lastCommand = $0 }
        let port = try await start(bridge)
        let backend = MCPBridgeClient(port:port,token:{"fixture-agent"})
        let server = await BacklitMCPServer.make { try await backend.request($0) }
        let pair = await InMemoryTransport.createConnectedPair()
        try await server.start(transport:pair.server)
        let client = MCP.Client(name:"Backlit fixture",version:"1")
        let initialized = try await client.connect(transport:pair.client)
        XCTAssertNotNil(initialized.capabilities.tools)
        let listing = try await client.listTools()
        XCTAssertEqual(listing.tools.count,4)
        let result: (content:[Tool.Content],isError:Bool?) = try await client.callTool(name:"backlit_set_power",arguments:["enabled":false])
        XCTAssertEqual(result.isError,false); XCTAssertEqual(lastCommand?.enabled,false)
        let mode: (content:[Tool.Content],isError:Bool?) = try await client.callTool(name:"backlit_set_mode",arguments:["mode":"trackpad"])
        XCTAssertEqual(mode.isError,false); XCTAssertEqual(lastCommand?.mode,.touch)
        await client.disconnect(); await server.stop()
    }
    @MainActor func testDisabledAgentAccessDoesNotDisableHomeAssistant() async throws {
        let server = HomeBridge(); defer { server.stop() }
        server.state = { ["enabled":true] }; server.agentState = { Self.state }
        let port = try await start(server,access:.off)
        let agent = MCPBridgeClient(port:port,token:{"fixture-agent"})
        do { _ = try await agent.request(nil); XCTFail("Disabled access accepted") }
        catch { XCTAssertEqual((error as? ExternalControlError)?.code,.authRequired) }
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/state")!)
        request.setValue("Bearer fixture-home",forHTTPHeaderField:"Authorization")
        let (_,response) = try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    }
    @MainActor func testKeyRotationRejectsOldAgentKeyAndRetainsHomeKey() async throws {
        let server = HomeBridge(); defer { server.stop() }
        server.agentState = { Self.state }; server.state = { ["enabled":true] }
        _ = try await start(server)
        server.stop()
        let port = try await start(server,token:"replacement-agent")
        let old = MCPBridgeClient(port:port,token:{"fixture-agent"})
        do { _ = try await old.request(nil); XCTFail("Old key accepted") }
        catch { XCTAssertEqual((error as? ExternalControlError)?.code,.authRequired) }
        let replacement = MCPBridgeClient(port:port,token:{"replacement-agent"})
        let replacementState = try await replacement.request(nil)
        XCTAssertEqual(replacementState.mode,"steady")
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/state")!)
        request.setValue("Bearer fixture-home",forHTTPHeaderField:"Authorization")
        let (_,response) = try await URLSession.shared.data(for:request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    }
    func testLoopbackIsAnEndpointPropertyAndCannotBeAssertedByAHeader() {
        XCTAssertTrue(HomeBridge.isLoopback(.hostPort(host:.ipv4(.loopback),port:123)))
        XCTAssertTrue(HomeBridge.isLoopback(.hostPort(host:.ipv6(.loopback),port:123)))
        XCTAssertFalse(HomeBridge.isLoopback(.hostPort(host:.ipv4(IPv4Address("192.0.2.5")!),port:123)))
        XCTAssertFalse(HomeBridge.isLoopback(.hostPort(host:.name("localhost",nil),port:123)))
    }
    @MainActor func testDisablingAccessCancelsAnAcceptedPartialAgentRequest() async throws {
        let server = HomeBridge(); defer { server.stop() }
        server.agentState = { Self.state }
        var writes = 0; server.agentCommand = { _ in writes += 1 }
        let port = try await start(server)
        let connection = NWConnection(host:.ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        defer { connection.cancel() }
        let ready = expectation(description:"partial agent connection ready")
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.start(queue:DispatchQueue(label:"Backlit.AgentDisableFixture"))
        await fulfillment(of:[ready],timeout:3)
        let body = Data(#"{"enabled":false}"#.utf8)
        let header = Data("POST /v1/agent/light HTTP/1.1\r\nAuthorization: Bearer fixture-agent\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        let sent = expectation(description:"partial header sent")
        connection.send(content:header,completion:.contentProcessed{_ in sent.fulfill()})
        await fulfillment(of:[sent],timeout:3)
        server.stop()
        connection.send(content:body,completion:.contentProcessed{_ in})
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertEqual(writes,0)
    }
}
