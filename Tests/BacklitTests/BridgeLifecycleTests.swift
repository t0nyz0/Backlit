import XCTest
import Network
@testable import Backlit

final class BridgeLifecycleTests: XCTestCase {
    @MainActor private func startedServer() async throws -> HomeBridge {
        let server = HomeBridge()
        let ready = expectation(description: "ephemeral listener ready")
        server.onStatus = { if $0.contains("Available") { ready.fulfill() } }
        try server.start(lan: false, token: "isolated-fixture-key", port: 0)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotEqual(server.port, 48261)
        return server
    }

    @MainActor func testStopCancelsAcceptedPartialRequestBeforeItCanMutate() async throws {
        let server = try await startedServer()
        defer { server.stop() }
        var calls = 0
        server.command = { _ in calls += 1 }
        let port = try XCTUnwrap(server.port)
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        let connected = expectation(description: "test connection ready")
        connection.stateUpdateHandler = { state in if case .ready = state { connected.fulfill() } }
        connection.start(queue: DispatchQueue(label: "Backlit.BridgeLifecycleTest"))
        await fulfillment(of: [connected], timeout: 5)
        for _ in 0..<100 where server.connectionCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(server.connectionCount, 1)
        let body = Data(#"{"enabled":false}"#.utf8)
        let header = "POST /v1/light HTTP/1.1\r\nAuthorization: Bearer isolated-fixture-key\r\nContent-Length: \(body.count)\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        server.stop()
        XCTAssertEqual(server.connectionCount, 0)
        connection.send(content: body, completion: .contentProcessed { _ in })
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testRemovedActivityEndpointRejectsWithoutMutationAndLightControlRemainsAvailable() async throws {
        let server = try await startedServer()
        defer { server.stop() }
        var calls = 0
        server.command = { _ in calls += 1 }
        let port = try XCTUnwrap(server.port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/signal")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"category":"build","state":"active","progress":0.5}"#.utf8)
        let (_, denied) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
        request.setValue("Bearer isolated-fixture-key", forHTTPHeaderField: "Authorization")
        let (_, removed) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((removed as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertEqual(calls, 0)
        request.url = URL(string: "http://127.0.0.1:\(port)/v1/light")!
        request.httpBody = Data(#"{"enabled":false}"#.utf8)
        let (_, accepted) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(calls, 1)
    }

}
