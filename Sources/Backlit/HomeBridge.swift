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
    /// Replaces the stored key with a new random one. The caller restarts the
    /// listener so the old key stops working immediately.
    @discardableResult static func regenerate() throws -> String {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.backlit",kSecAttrAccount as String:account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RuntimeServices.failure("Keychain could not remove the old pairing key (\(status)).") }
        return try value()
    }
}

/// Replacing a pairing key is what someone does when the old key may have
/// been seen. The listener holds its key in memory, so it must stop before
/// the stored key changes, and it must stay stopped if the new key cannot be
/// created. Otherwise a failed rotation would leave the old key working.
enum PairingKeyRotation {
    enum Outcome: Equatable {
        case rotated(restartSharing: Bool)
        case failed(String)
    }
    static func run(wasSharing: Bool, stopSharing: () -> Void, regenerate: () throws -> Void) -> Outcome {
        stopSharing()
        do { try regenerate() } catch { return .failed(error.localizedDescription) }
        return .rotated(restartSharing: wasSharing)
    }
}

struct BridgeRequest {
    let method: String
    let path: String
    let headers: [String:String]
    let body: Data
    static func parse(_ data: Data) throws -> BridgeRequest? {
        guard data.count <= 16384 else { throw RuntimeServices.failure("Request too large.") }
        let terminator = Data("\r\n\r\n".utf8)
        guard let split = data.range(of: terminator) else {
            // Up to three trailing bytes may already belong to a fragmented
            // terminator. Count only bytes that are definitely header content.
            let partialTerminator = (1...3).reversed().first { length in
                data.count >= length && data.suffix(length).elementsEqual(terminator.prefix(length))
            } ?? 0
            guard data.count - partialTerminator < 8192 else { throw RuntimeServices.failure("Invalid HTTP headers.") }
            return nil
        }
        guard split.lowerBound < 8192, let text = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw RuntimeServices.failure("Invalid HTTP headers.") }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        func token(_ value: some StringProtocol) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy {
                switch $0 {
                case 48...57, 65...90, 97...122, 33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126: return true
                default: return false
                }
            }
        }
        guard first.count == 3, token(first[0]),
              first[1].utf8.allSatisfy({ (33...126).contains($0) }),
              first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw RuntimeServices.failure("Invalid HTTP request.") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RuntimeServices.failure("Invalid header.") }
            let name = line[..<colon]
            guard token(name) else { throw RuntimeServices.failure("Invalid header name.") }
            let raw = line[line.index(after: colon)...]
            // RFC field values allow SP, HTAB, visible bytes and obs-text,
            // but embedded controls or an obsolete folded field are invalid.
            guard raw.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { throw RuntimeServices.failure("Invalid header value.") }
            let key = name.lowercased()
            guard headers[key] == nil else { throw RuntimeServices.failure("Duplicate header.") }
            headers[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        }
        guard headers["transfer-encoding"] == nil else { throw RuntimeServices.failure("Chunked requests are not supported.") }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(raw), (0...8192).contains(value) else { throw RuntimeServices.failure("Invalid content length.") }
            length = value
        } else { length = 0 }
        guard data.count >= split.upperBound + length else { return nil }
        guard data.count == split.upperBound + length else { throw RuntimeServices.failure("Unexpected pipelined data.") }
        return BridgeRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(data[split.upperBound...]))
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

private final class BridgeSession {
    private let lock = NSLock()
    private var active = true
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }
    func attach(_ connection: NWConnection) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active, connections.count < 32 else { return false }
        connections[ObjectIdentifier(connection)] = connection
        return true
    }
    func detach(_ connection: NWConnection) {
        lock.lock(); connections.removeValue(forKey: ObjectIdentifier(connection)); lock.unlock()
    }
    func invalidate() {
        lock.lock()
        active = false
        let pending = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        pending.forEach { $0.cancel() }
    }
}

final class HomeBridge {
    private var listener: NWListener?
    private var session: BridgeSession?
    private var listenerStarted = false
    private var retiring: [ObjectIdentifier: NWListener] = [:]
    private var generation: UInt64 = 0
    private var pendingDeadline: DispatchWorkItem?
    private let queue = DispatchQueue(label:"Backlit.HomeBridge")
    var port: UInt16? { listener?.port?.rawValue }
    var connectionCount: Int { session?.connectionCount ?? 0 }
    var state: (() -> [String:Any])?
    var command: ((LightCommand) throws -> Void)?
    var onStatus: ((String) -> Void)?
    func start(lan: Bool, token: String, port: UInt16 = 48261) throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:lan ? .ipv4(.any) : .ipv4(.loopback),port:NWEndpoint.Port(rawValue:port)!)
        let candidate = try NWListener(using:parameters)
        let current = BridgeSession()
        let identity = ObjectIdentifier(candidate), requestedGeneration = generation
        candidate.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                if case .cancelled = state {
                    self?.retiring.removeValue(forKey: identity)
                    self?.startPendingListener()
                    return
                }
                guard current.isActive else { return }
                switch state {
                case .ready: self?.onStatus?(lan ? "Available on your local network" : "Available on this Mac")
                case .failed(let error): self?.onStatus?(error.localizedDescription)
                default: break
                }
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            guard let self, current.attach(connection) else { connection.cancel(); return }
            connection.stateUpdateHandler = { [weak connection, weak current = current] state in
                if case .cancelled = state, let connection { current?.detach(connection) }
                if case .failed = state, let connection { current?.detach(connection) }
            }
            connection.start(queue:self.queue)
            self.receive(connection,data:Data(),token:token,session:current)
            self.queue.asyncAfter(deadline:.now()+5) { [weak connection, weak current = current] in
                if let connection { current?.detach(connection); connection.cancel() }
            }
        }
        session = current; listener = candidate; listenerStarted = false
        if !retiring.isEmpty {
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.generation == requestedGeneration, !self.listenerStarted else { return }
                self.stop()
                self.onStatus?("The previous local connection is still closing. Turn sharing off and on to retry.")
            }
            pendingDeadline = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        }
        startPendingListener()
    }
    private func startPendingListener() {
        guard retiring.isEmpty, !listenerStarted, let listener, session?.isActive == true else { return }
        pendingDeadline?.cancel(); pendingDeadline = nil
        listenerStarted = true
        listener.start(queue: queue)
    }
    func stop() {
        // Invalidate before cancelling: already parsed callbacks must not apply
        // commands after sharing is disabled or a replacement listener starts.
        generation &+= 1
        pendingDeadline?.cancel(); pendingDeadline = nil
        session?.invalidate(); session = nil
        if let listener {
            if listenerStarted {
                // Cancellation is asynchronous. Keep the old listener alive
                // until .cancelled confirms its bind is being retired; a new
                // exclusive bind must not race the old socket's teardown.
                retiring[ObjectIdentifier(listener)] = listener
                listener.cancel()
            } else {
                listener.stateUpdateHandler = nil
                listener.cancel()
            }
        }
        listener = nil; listenerStarted = false
    }
    private func receive(_ connection: NWConnection, data: Data, token: String, session: BridgeSession) {
        guard session.isActive else { connection.cancel(); return }
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] bytes,_,complete,error in
            guard let self, session.isActive else { connection.cancel(); return }
            var combined = data; if let bytes { combined.append(bytes) }
            do {
                guard let request = try BridgeRequest.parse(combined) else {
                    if complete || error != nil { connection.cancel() }
                    else { self.receive(connection,data:combined,token:token,session:session) }
                    return
                }
                guard request.authorized(token) else { self.send(connection,status:401,value:["error":"Pairing key required"]); return }
                DispatchQueue.main.async {
                    guard session.isActive else { connection.cancel(); return }
                    do {
                        if request.method == "POST" && request.path == "/v1/light" {
                            guard let command = self.command else { throw RuntimeServices.failure("Light control is unavailable.") }
                            try command(LightCommand(data:request.body))
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
    deinit {
        pendingDeadline?.cancel()
        session?.invalidate(); listener?.cancel()
        retiring.values.forEach { $0.cancel() }
    }
}
