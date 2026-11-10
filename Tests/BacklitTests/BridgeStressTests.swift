import XCTest
import Network
@testable import Backlit

final class BridgeStressTests: XCTestCase {
    private enum FixtureError: Error { case startup(String), malformedResponse }
    private let token = "isolated-stress-fixture"
    private let queue = DispatchQueue(label: "Backlit.BridgeStressFixture")

    // All mutable state in these fixture-only boxes is protected by a lock.
    private final class Bytes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()
        func append(_ bytes: Data?) { lock.lock(); if let bytes { value.append(bytes) }; lock.unlock() }
        var snapshot: Data { lock.lock(); defer { lock.unlock() }; return value }
    }
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func finish(_ action: () -> Void) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true; lock.unlock(); action()
        }
    }

    @MainActor private func start(_ server: HomeBridge = HomeBridge(), port: UInt16 = 0) async throws -> (HomeBridge, UInt16) {
        let ready = expectation(description: "isolated bridge ready")
        var state = ""
        server.onStatus = { value in state = value; ready.fulfill() }
        try server.start(lan: false, token: token, port: port)
        await fulfillment(of: [ready], timeout: 3)
        guard state.contains("Available"), let bound = server.port else { throw FixtureError.startup(state) }
        XCTAssertNotEqual(bound, 48261, "Never use the installed app's port")
        return (server, bound)
    }

    @MainActor private func connect(_ port: UInt16) async -> NWConnection {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "fixture connection ready")
        connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        connection.start(queue: queue)
        await fulfillment(of: [ready], timeout: 3)
        connection.stateUpdateHandler = nil
        return connection
    }

    private func request(_ body: Data = Data(), auth: String? = nil, path: String = "/v1/light", method: String = "POST", extra: String = "") -> Data {
        let authorization = auth.map { "Authorization: Bearer \($0)\r\n" } ?? ""
        var result = Data("\(method) \(path) HTTP/1.1\r\n\(authorization)Content-Length: \(body.count)\r\n\(extra)\r\n".utf8)
        result.append(body)
        return result
    }

    @MainActor private func exchange(_ port: UInt16, fragments: [Data]) async -> Data {
        let connection = await connect(port)
        defer { connection.cancel() }
        for fragment in fragments {
            let sent = expectation(description: "fixture fragment sent")
            connection.send(content: fragment, completion: .contentProcessed { _ in sent.fulfill() })
            await fulfillment(of: [sent], timeout: 3)
        }
        let response = Bytes(), ended = expectation(description: "fixture response ended")
        let once = Once()
        Self.collect(connection, into: response, finished: ended, once: once)
        await fulfillment(of: [ended], timeout: 3)
        return response.snapshot
    }

    private static func collect(_ connection: NWConnection, into response: Bytes, finished: XCTestExpectation, once: Once) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            response.append(data)
            if complete || error != nil { once.finish { finished.fulfill() } }
            else { Self.collect(connection, into: response, finished: finished, once: once) }
        }
    }

    private func status(_ data: Data) throws -> Int {
        let text = String(decoding: data, as: UTF8.self)
        guard let first = text.components(separatedBy: "\r\n").first,
              let value = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw FixtureError.malformedResponse }
        return value
    }

    @MainActor private func assertResponse(_ port: UInt16, request: Data, status expected: Int) async throws {
        let response = await exchange(port, fragments: [request])
        XCTAssertEqual(try status(response), expected)
    }

    @MainActor func testByteFragmentedCommandRunsExactlyOnceAfterCompleteFrame() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        var commands: [LightCommand] = []
        server.command = { commands.append($0) }
        server.state = { ["calls": commands.count] }
        let body = Data(#"{"brightness":128,"effect":"Breathe","enabled":true}"#.utf8)
        let data = request(body, auth: token)
        let response = await exchange(port, fragments: data.map { Data([$0]) })
        XCTAssertEqual(try status(response), 200)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.enabled, true)
        XCTAssertEqual(commands.first?.mode, .breathe)
    }

    @MainActor func testRejectedRequestsAndHandlerFailureDoNotPoisonListener() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        var calls = 0
        server.command = { _ in calls += 1 }
        let body = Data(#"{"enabled":false}"#.utf8)
        for invalid in [request(body), request(body, auth: token + "x"), request(body, auth: token, extra: "Origin: https://example.invalid\r\n")] {
            try await assertResponse(port, request: invalid, status: 401)
        }
        XCTAssertEqual(calls, 0)
        let malformed = Data("POST /v1/light HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: +2\r\n\r\n{}".utf8)
        try await assertResponse(port, request: malformed, status: 400)
        XCTAssertEqual(calls, 0)
        try await assertResponse(port, request: request(auth: token, path: "/unknown", method: "GET"), status: 404)
        server.command = { _ in throw FixtureError.startup("isolated handler failure") }
        try await assertResponse(port, request: request(body, auth: token), status: 400)
        server.command = { _ in calls += 1 }
        try await assertResponse(port, request: request(body, auth: token), status: 200)
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testAcceptedConnectionsStayBoundedAndStopClosesEverySession() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        var held: [NWConnection] = []
        defer { held.forEach { $0.cancel() } }
        for _ in 0..<32 { held.append(await connect(port)) }
        for _ in 0..<100 where server.connectionCount != 32 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(server.connectionCount, 32)
        let rejected = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { rejected.cancel() }
        let closed = expectation(description: "over-capacity connection closed")
        let once = Once()
        rejected.stateUpdateHandler = { state in
            if case .failed = state { once.finish { closed.fulfill() } }
            if case .cancelled = state { once.finish { closed.fulfill() } }
        }
        rejected.start(queue: queue)
        rejected.receive(minimumIncompleteLength: 1, maximumLength: 64) { _, _, complete, error in
            if complete || error != nil { once.finish { closed.fulfill() } }
        }
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertEqual(server.connectionCount, 32)
        server.stop()
        XCTAssertEqual(server.connectionCount, 0)
        let (restarted, _) = try await start(server)
        XCTAssertTrue(restarted === server)
        XCTAssertEqual(restarted.connectionCount, 0)
    }

    @MainActor func testStopRestartOnSamePortRejectsOldPartialCommand() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        var calls = 0
        server.command = { _ in calls += 1 }
        let old = await connect(port)
        defer { old.cancel() }
        let body = Data(#"{"enabled":false}"#.utf8)
        let data = request(body, auth: token)
        let header = Data(data.dropLast(body.count))
        let sent = expectation(description: "old partial frame sent")
        old.send(content: header, completion: .contentProcessed { _ in sent.fulfill() })
        await fulfillment(of: [sent], timeout: 3)
        server.stop()
        _ = try await start(server, port: port)
        old.send(content: body, completion: .contentProcessed { _ in })
        let response = await exchange(port, fragments: [request(body, auth: token)])
        XCTAssertEqual(try status(response), 200)
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testRapidRestartSupersedesUnstartedListeners() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        let ready = expectation(description: "only the latest restart becomes ready")
        var readyEvents = 0
        server.onStatus = { value in
            XCTAssertTrue(value.contains("Available"), value)
            readyEvents += 1
            if readyEvents == 1 { ready.fulfill() }
        }
        for _ in 0..<8 { try server.start(lan: false, token: token, port: port) }
        await fulfillment(of: [ready], timeout: 3)
        let response = await exchange(port, fragments: [request(auth: token, path: "/v1/state", method: "GET")])
        XCTAssertEqual(try status(response), 200)
        XCTAssertEqual(readyEvents, 1)
    }

    @MainActor func testConcurrentValidAndInvalidTrafficHasExactMutationCount() async throws {
        let (server, port) = try await start()
        defer { server.stop() }
        var calls = 0
        server.command = { _ in calls += 1 }
        server.state = { ["calls": calls] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 16
        configuration.timeoutIntervalForRequest = 3
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let codes = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<24 {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/light")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = Data((index.isMultiple(of: 2) ? #"{"enabled":false}"# : #"{"brightness":true}"#).utf8)
                let prepared = request
                group.addTask {
                    let (_, response) = try await client.data(for: prepared)
                    return (response as? HTTPURLResponse)?.statusCode ?? -1
                }
            }
            var result: [Int] = []
            for try await code in group { result.append(code) }
            return result
        }
        XCTAssertEqual(codes.filter { $0 == 200 }.count, 12)
        XCTAssertEqual(codes.filter { $0 == 400 }.count, 12)
        XCTAssertEqual(calls, 12)
    }
}
