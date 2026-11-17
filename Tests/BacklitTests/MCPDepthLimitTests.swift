import XCTest
@testable import Backlit

/// Own pipes only: rejected JSON never reaches an SDK handler or light backend.
final class MCPDepthLimitTests: XCTestCase {
    private func ping(totalDepth: Int) -> Data {
        precondition(totalDepth >= 2)
        let arrays = totalDepth - 2 // The request and params objects also count.
        return Data((#"{"jsonrpc":"2.0","id":11,"method":"ping","params":{"extra":"# +
                     String(repeating: "[", count: arrays) + "0" +
                     String(repeating: "]", count: arrays) + "}}").utf8)
    }

    private func received(_ fragments: [Data]) async throws -> [Data] {
        let input = Pipe(), output = Pipe()
        defer {
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        let transport = BoundedMCPTransport(input: input.fileHandleForReading.fileDescriptor,
                                            output: output.fileHandleForWriting.fileDescriptor)
        try await transport.connect()
        let finished = expectation(description: "Depth fixture stream completed")
        let reader = Task { () throws -> [Data] in
            defer { finished.fulfill() }
            var lines: [Data] = []
            for try await line in await transport.receive() { lines.append(line) }
            return lines
        }
        for fragment in fragments { try input.fileHandleForWriting.write(contentsOf: fragment) }
        try input.fileHandleForWriting.close()
        await fulfillment(of: [finished], timeout: 3)
        await transport.disconnect()
        return try await reader.value
    }

    func testExactly64ContainersReachTheSDKBoundaryUnmodified() async throws {
        let line = ping(totalDepth: 64)
        let lines = try await received([line + Data([10])])
        XCTAssertEqual(lines, [line])
    }

    func test65ContainersCloseWithoutYieldingToTheSDK() async throws {
        let lines = try await received([ping(totalDepth: 65) + Data([10])])
        XCTAssertEqual(lines, [])
    }

    func test256NestedArraysCloseWithoutYieldingTheCrashReproduction() async throws {
        // The retained real-process failure has256 arrays inside2 request objects.
        let lines = try await received([ping(totalDepth: 258) + Data([10])])
        XCTAssertEqual(lines, [])
    }
}
