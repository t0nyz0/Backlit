import XCTest
@testable import Backlit

final class CrossLanguageClientTests: XCTestCase {
    @MainActor private func server() async throws -> HomeBridge {
        let bridge = HomeBridge()
        let ready = expectation(description: "isolated Swift bridge ready")
        bridge.onStatus = { if $0.contains("Available") { ready.fulfill() } }
        try bridge.start(lan: false, token: "cross-language-fixture", port: 0)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotEqual(bridge.port, 48261)
        return bridge
    }

    @MainActor private func client(port: UInt16, arguments: [String], token: String = "cross-language-fixture") async throws -> Int32 {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("integrations/activity/backlit_signal.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, "--port", String(port)] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BACKLIT_TOKEN"] = token
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = expectation(description: "isolated Python client completed")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        await fulfillment(of: [finished], timeout: 10)
        if process.isRunning { process.terminate(); throw RuntimeServices.failure("Fixture Python client did not finish") }
        return process.terminationStatus
    }

    @MainActor func testRealPythonClientDrivesSwiftValidationAndSignalEngine() async throws {
        let bridge = try await server()
        defer { bridge.stop() }
        var engine = ActivitySignalEngine()
        var accepted = 0
        bridge.signal = { signal in engine.submit(signal, at: 0); accepted += 1 }
        bridge.state = {
            var input = EffectInput(); input.mode = .signals; input.brightness = 0.6
            input.signalLevel = engine.level(at: 0)
            return ["output": Effects.level(at: 0, input: input), "signal_count": engine.count]
        }
        let port = try XCTUnwrap(bridge.port)
        let code = try await client(port: port, arguments: ["signal", "build", "active", "--progress", "0.75"])
        XCTAssertEqual(code, 0); XCTAssertEqual(accepted, 1)
        XCTAssertEqual(engine.level(at: 0), 0.795, accuracy: 0.000001)
        let denied = try await client(port: port, arguments: ["signal", "build", "clear"], token: "wrong-fixture")
        XCTAssertEqual(denied, 2); XCTAssertEqual(accepted, 1)
        let invalid = try await client(port: port, arguments: ["signal", "build", "active", "--progress", "nan"])
        XCTAssertEqual(invalid, 2); XCTAssertEqual(accepted, 1)
    }

    @MainActor func testRealWrappedJobCompletesAgainstNativeBridge() async throws {
        let bridge = try await server()
        defer { bridge.stop() }
        var events: [ActivitySignal] = []
        bridge.signal = { events.append($0) }
        bridge.state = { ["signal_count": events.count] }
        let port = try XCTUnwrap(bridge.port)
        let code = try await client(port: port, arguments: ["run", "export", "--", "/usr/bin/true"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(events.map(\.state), [.active, .complete])
        XCTAssertEqual(events.map(\.category), [.export, .export])
        XCTAssertEqual(events.map(\.effectiveDuration), [90, 8])
    }
}
