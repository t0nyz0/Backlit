import Foundation
import Network
import Security

enum BridgeToken {
    static let account = "home-assistant"
    static func value() throws -> String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.backlit",kSecAttrAccount as String:account]
        var result: CFTypeRef?
        var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(read as CFDictionary,&result)
        if status == errSecSuccess, let data = result as? Data, let token = String(data:data,encoding:.utf8) { return token }
        guard status == errSecItemNotFound else { throw RuntimeServices.failure("Keychain could not read the Home Assistant key (\(status)).") }
        var random = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,random.count,&random) == errSecSuccess else { throw RuntimeServices.failure("Could not generate a pairing key.") }
        let token = Data(random).base64EncodedString()
        var item = query; item[kSecValueData as String] = Data(token.utf8); item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw RuntimeServices.failure("Keychain could not save the pairing key.") }
        return token
    }
}

struct BridgeRequest {
    let method: String
    let path: String
    let headers: [String:String]
    let body: Data
    static func parse(_ data: Data) throws -> BridgeRequest? {
        guard data.count <= 16384 else { throw RuntimeServices.failure("Request too large.") }
        guard let split = data.range(of:Data("\r\n\r\n".utf8)) else { return nil }
        guard split.lowerBound < 8192, let text = String(data:data[..<split.lowerBound],encoding:.utf8) else { throw RuntimeServices.failure("Invalid HTTP headers.") }
        let lines = text.components(separatedBy:"\r\n")
        let first = lines[0].split(separator:" ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw RuntimeServices.failure("Invalid HTTP request.") }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":") else { throw RuntimeServices.failure("Invalid header.") }
            let key = String(line[..<colon]).lowercased()
            guard headers[key] == nil else { throw RuntimeServices.failure("Duplicate header.") }
            headers[key] = String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw RuntimeServices.failure("Chunked requests are not supported.") }
        let length: Int
        if let raw = headers["content-length"] { guard let value = Int(raw), (0...8192).contains(value) else { throw RuntimeServices.failure("Invalid content length.") }; length = value }
        else { length = 0 }
        guard data.count >= split.upperBound + length else { return nil }
        guard data.count == split.upperBound + length else { throw RuntimeServices.failure("Unexpected pipelined data.") }
        return BridgeRequest(method:String(first[0]),path:String(first[1]),headers:headers,body:Data(data[split.upperBound...]))
    }
    func authorized(_ token: String) -> Bool {
        guard headers["origin"] == nil, let value = headers["authorization"], value.hasPrefix("Bearer ") else { return false }
        let lhs = Array(value.dropFirst(7).utf8), rhs = Array(token.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs,rhs).reduce(UInt8(0)){ $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct LightCommand {
    var enabled: Bool?
    var brightness: Double?
    var mode: GlowMode?
    init(data: Data) throws {
        guard let value = try JSONSerialization.jsonObject(with:data) as? [String:Any], !value.isEmpty,
              Set(value.keys).isSubset(of:["enabled","brightness","effect"]) else { throw RuntimeServices.failure("Expected enabled, brightness, or effect.") }
        if let raw = value["enabled"] {
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw RuntimeServices.failure("enabled must be a boolean.") }
            enabled = n.boolValue
        }
        if let raw = value["brightness"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  (0...255).contains(number.doubleValue) else { throw RuntimeServices.failure("brightness must be between 0 and 255.") }
            brightness = number.doubleValue / 255
        }
        if let raw = value["effect"] {
            guard let name = raw as? String, let parsed = GlowMode(rawValue:name.lowercased() == "trackpad" ? "touch" : name.lowercased()) else { throw RuntimeServices.failure("Unknown effect.") }
            mode = parsed
        }
    }
}

final class HomeBridge {
    private var listener: NWListener?
    private let queue = DispatchQueue(label:"Backlit.HomeBridge")
    var port: UInt16? { listener?.port?.rawValue }
    var state: (() -> [String:Any])?
    var command: ((LightCommand) throws -> Void)?
    var onStatus: ((String) -> Void)?
    var signal: ((ActivitySignal) throws -> Void)?
    func start(lan: Bool, token: String, port: UInt16 = 48261) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:lan ? .ipv4(.any) : .ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!)
        let candidate = try NWListener(using:parameters)
        candidate.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { switch state {
            case .ready: self?.onStatus?(lan ? "Available on your local network" : "Available on this Mac")
            case .failed(let error): self?.onStatus?(error.localizedDescription)
            default: break
            } }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            connection.start(queue:self?.queue ?? .global())
            self?.receive(connection,data:Data(),token:token)
            self?.queue.asyncAfter(deadline:.now()+5) { connection.cancel() }
        }
        listener = candidate; candidate.start(queue:queue)
    }
    func stop() { listener?.cancel(); listener = nil }
    private func receive(_ connection: NWConnection, data: Data, token: String) {
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] bytes,_,complete,error in
            guard let self else { connection.cancel(); return }
            var combined = data; if let bytes { combined.append(bytes) }
            do {
                guard let request = try BridgeRequest.parse(combined) else {
                    if complete || error != nil { connection.cancel() } else { self.receive(connection,data:combined,token:token) }; return
                }
                guard request.authorized(token) else { self.send(connection,status:401,value:["error":"Pairing key required"]); return }
                DispatchQueue.main.async {
                    do {
                        if request.method == "POST" && request.path == "/v1/light" {
                            try self.command?(LightCommand(data:request.body))
                        } else if request.method == "POST" && request.path == "/v1/signal" {
                            guard let signal = self.signal else { throw RuntimeServices.failure("Activity signals are unavailable.") }
                            try signal(ActivitySignal(data: request.body))
                        } else if request.method != "GET" || request.path != "/v1/state" {
                            self.send(connection,status:404,value:["error":"Unknown endpoint"]); return
                        }
                        self.send(connection,status:200,value:self.state?() ?? [:])
                    } catch { self.send(connection,status:400,value:["error":error.localizedDescription]) }
                }
            } catch { self.send(connection,status:400,value:["error":"Invalid request"] ) }
        }
    }
    private func send(_ connection: NWConnection, status: Int, value: [String:Any]) {
        let body = (try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content:response,completion:.contentProcessed{_ in connection.cancel()})
    }
}
