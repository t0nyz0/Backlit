import Foundation
import AppKit
import MCP

/// Refuse redirects, proxies, cookies and caches: this client has exactly one
/// local destination and never sends its credential to a supplied URL.
private final class MCPNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct MCPBridgeClient: Sendable {
    let port: UInt16
    let token: @Sendable () throws -> String
    init(port: UInt16 = 48261, token: @escaping @Sendable () throws -> String = { try MCPBridgeClient.localToken() }) {
        self.port = port; self.token = token
    }
    static func localToken() throws -> String {
        guard NSRunningApplication.runningApplications(withBundleIdentifier:"local.backlit").contains(where:{$0.processIdentifier != getpid()}) else {
            throw ExternalControlError(.appNotRunning, "Open Backlit before using its AI connection.")
        }
        let access = localAccess()
        guard access != "off" else { throw ExternalControlError(.accessDisabled, "Enable MCP control in Backlit Connections first.") }
        return try BridgeToken.value(account:BridgeToken.agentAccount,create:false,interactive:false)
    }
    static func localAccess(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
                            standard: () -> String? = { UserDefaults.standard.string(forKey:"mcp.access") },
                            suite: () -> String? = { UserDefaults(suiteName:"local.backlit")?.string(forKey:"mcp.access") }) -> String {
        // Foundation refuses to add the process's own application domain as a
        // suite. The installed --mcp executable shares the GUI's bundle ID.
        // An unbundled development executable must select that domain by name.
        return (bundleIdentifier == "local.backlit" ? standard() : suite()) ?? "off"
    }
    func request(_ command: [String:Value]?) async throws -> AgentLightState {
        let credential = try token()
        let path = command == nil ? "state" : "light"
        var request = URLRequest(url:URL(string:"http://127.0.0.1:\(port)/v1/agent/\(path)")!)
        request.httpMethod = command == nil ? "GET" : "POST"
        request.setValue("Bearer " + credential,forHTTPHeaderField:"Authorization")
        if let command {
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONEncoder().encode(command)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 2; configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration:configuration,delegate:MCPNoRedirects(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes,response) = try await session.bytes(for:request)
            var data = Data()
            for try await byte in bytes {
                guard data.count < 32_768 else { throw ExternalControlError(.unavailable, "Backlit returned an oversized response.") }
                data.append(byte)
            }
            guard let response = response as? HTTPURLResponse else { throw ExternalControlError(.unavailable, "Backlit returned an invalid response.") }
            guard response.statusCode == 200 else {
                let error = (try? JSONDecoder().decode([String:String].self,from:data)) ?? [:]
                let code = error["code"].flatMap(ExternalControlError.Code.init(rawValue:)) ?? (response.statusCode == 401 ? .authRequired : .unavailable)
                throw ExternalControlError(code,error["error"] ?? "Backlit refused this request. Open Connections and check AI access.")
            }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(AgentLightState.self,from:data)
        } catch let error as ExternalControlError { throw error }
        catch let error as URLError {
            if error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
                throw ExternalControlError(.appNotRunning, "Backlit's AI connection is unavailable. Open Backlit and check Connections.")
            }
            throw ExternalControlError(.unavailable, "The light request could not be confirmed. Read status before retrying.")
        } catch { throw ExternalControlError(.unavailable, "Backlit returned an unreadable response. Read status before retrying.") }
    }
}

actor BacklitMCPTools {
    typealias Backend = @Sendable ([String:Value]?) async throws -> AgentLightState
    private let backend: Backend
    private var inFlight = 0
    init(backend: @escaping Backend) { self.backend = backend }

    static let tools: [Tool] = [
        tool("backlit_get_status", "Read requested light settings, calculated output, hardware readback and availability. Output is not an optical measurement.", properties:[:], readOnly:true),
        tool("backlit_set_power", "Set the light on or off. Repeating the same setting is safe. Requires Allow light changes in Backlit.", properties:["enabled":["type":"boolean"]]),
        tool("backlit_set_brightness", "Set manual brightness from 0 to 100 percent. Battery mode is automatic; select a manual mode first if asked.", properties:["percent":["type":"number","minimum":0,"maximum":100]]),
        tool("backlit_set_mode", "Select an available behavior. Music and Typing need local setup first. Does not enable permissions or change power policy.", properties:["mode":["type":"string","enum":.array(GlowMode.allCases.map{.string($0.externalName)})]])
    ]
    private static let outputSchema: Value = ["type":"object","oneOf":[
        ["type":"object","properties":[
            "access":["type":"string","enum":["off","status","control"]],
            "enabled":["type":"boolean"],"mode":["type":"string"],
            "manual_brightness_percent":["type":"number","minimum":0,"maximum":100],
            "calculated_output_percent":["type":"number","minimum":0,"maximum":100],
            "hardware_enabled":["type":"boolean"],"hardware_sample_age_seconds":["type":"number","minimum":0],
            "hardware_supported":["type":"boolean"],"controlling":["type":"boolean"],"preview":["type":"boolean"],"recovery_required":["type":"boolean"],
            "busy":["type":"boolean"],"paused":["type":"string"],"observed_at":["type":"string"],
            "application_result":["type":"string","enum":["applied","waiting","paused","unavailable","recovery_required"]],
            "available_modes":["type":"array","items":["type":"object","properties":[
                "name":["type":"string"],"selectable":["type":"boolean"],"reason":["type":"string"]
            ],"required":["name","selectable"],"additionalProperties":false]]
        ],"required":["access","enabled","mode","manual_brightness_percent","calculated_output_percent",
                      "hardware_supported","controlling","preview","recovery_required","busy","observed_at","application_result","available_modes"],
         "additionalProperties":false],
        ["type":"object","properties":["code":["type":"string"],"message":["type":"string"]],
         "required":["code","message"],"additionalProperties":false]
    ]]
    private static func tool(_ name: String, _ description: String, properties: [String:Value], readOnly: Bool = false) -> Tool {
        Tool(name:name,description:description,
            inputSchema:["type":"object","properties":.object(properties),"required":.array(properties.keys.sorted().map{.string($0)}),"additionalProperties":false],
            annotations:.init(readOnlyHint:readOnly,destructiveHint:false,idempotentHint:true,openWorldHint:false),outputSchema:outputSchema)
    }
    static func command(name: String, arguments: [String:Value]) throws -> [String:Value]? {
        func keys(_ expected: Set<String>) throws {
            guard Set(arguments.keys) == expected else { throw ExternalControlError(.invalidArgument, "Supply exactly the fields in this tool's schema.") }
        }
        switch name {
        case "backlit_get_status": try keys([]); return nil
        case "backlit_set_power":
            try keys(["enabled"])
            guard case .bool = arguments["enabled"] else { throw ExternalControlError(.invalidArgument, "enabled must be a boolean.") }
            return arguments
        case "backlit_set_brightness":
            try keys(["percent"])
            let percent: Double
            switch arguments["percent"] {
            case .int(let value): percent = Double(value)
            case .double(let value): percent = value
            default: throw ExternalControlError(.invalidArgument, "percent must be a number from 0 to 100.")
            }
            guard percent.isFinite, (0...100).contains(percent) else { throw ExternalControlError(.invalidArgument, "percent must be finite and from 0 to 100.") }
            return ["brightness":.double(percent / 100 * 255)]
        case "backlit_set_mode":
            try keys(["mode"])
            guard let name = arguments["mode"]?.stringValue,
                  let selected = GlowMode.allCases.first(where:{$0.externalName == name}) else {
                throw ExternalControlError(.invalidArgument, "Select a mode from backlit_get_status.")
            }
            return ["effect":.string(selected.rawValue)]
        default: throw ExternalControlError(.invalidArgument, "Unknown Backlit tool.")
        }
    }
    func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let command = try Self.command(name:parameters.name,arguments:parameters.arguments ?? [:])
            guard inFlight < 4 else { throw ExternalControlError(.busy, "Too many Backlit requests. Wait and read status before retrying.") }
            inFlight += 1; defer { inFlight -= 1 }
            let state = try await backend(command)
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            let value = try JSONDecoder().decode(Value.self,from:data)
            return .init(content:[.text(text:String(decoding:data,as:UTF8.self),annotations:nil,_meta:nil)],structuredContent:.some(value),isError:false)
        } catch {
            let failure = error as? ExternalControlError ?? ExternalControlError(.unavailable,"Backlit could not confirm the request. Read status before retrying.")
            return .init(content:[.text(text:failure.message,annotations:nil,_meta:nil)],structuredContent:.some(.object(["code":.string(failure.code.rawValue),"message":.string(failure.message)])),isError:true)
        }
    }
}

private actor MCPInitialization {
    private var initialized = false
    func initialize() { initialized = true }
    func requireInitialized() throws {
        guard initialized else { throw MCPError.invalidRequest("Initialize the Backlit connection first.") }
    }
}

struct BacklitMCPConnection: Sendable {
    let server: Server
    private let initialization: MCPInitialization
    fileprivate init(server: Server, initialization: MCPInitialization) {
        self.server = server; self.initialization = initialization
    }
    func start(transport: any Transport) async throws {
        try await server.start(transport:transport) { _,_ in await initialization.initialize() }
    }
    func waitUntilCompleted() async { await server.waitUntilCompleted() }
    func stop() async { await server.stop() }
}

enum BacklitMCPServer {
    static func make(backend: @escaping BacklitMCPTools.Backend) async -> BacklitMCPConnection {
        let server = Server(name:"Backlit",version:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development",
            instructions:"Control only this Mac's Backlit light when asked. Check status and available modes first. Calculated output is not measured light. Settings persist after disconnect. Keep automatic status hooks separate.",
            capabilities:.init(tools:.init()))
        // Gate inside handlers so a pre-initialize call receives a protocol
        // error. The pinned SDK's strict pre-handler check drops that reply.
        let initialization = MCPInitialization()
        let tools = BacklitMCPTools(backend:backend)
        await server.withMethodHandler(ListTools.self) { _ in
            try await initialization.requireInitialized()
            return .init(tools:BacklitMCPTools.tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            try await initialization.requireInitialized()
            return await tools.call(parameters)
        }
        return BacklitMCPConnection(server:server,initialization:initialization)
    }
    static func run() async -> Int32 {
        signal(SIGPIPE,SIG_IGN)
        let client = MCPBridgeClient()
        let server = await make { try await client.request($0) }
        do {
            try await server.start(transport:BoundedMCPTransport())
            await server.waitUntilCompleted()
            await server.stop()
            return 0
        } catch {
            // Fixed text only; never put incoming tool content or credentials in logs.
            FileHandle.standardError.write(Data("Backlit MCP could not open its standard streams.\n".utf8))
            return 1
        }
    }
}
