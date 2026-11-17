import XCTest
@testable import Backlit

final class MCPNestingGuardTests: XCTestCase {
    func testExactLimitMixedContainersAndOverflow() {
        let valid = String(repeating: "[{\"x\":", count: 32) + "0" + String(repeating: "}]", count: 32)
        XCTAssertTrue(MCPJSONNesting.accepts(Data(valid.utf8)))
        XCTAssertFalse(MCPJSONNesting.accepts(Data(("[" + valid + "]").utf8)))
        XCTAssertFalse(MCPJSONNesting.accepts(Data((String(repeating: "[", count: 256) + "0" + String(repeating: "]", count: 256)).utf8)))
    }
    func testQuotedBracketsAndEscapedQuotesDoNotCount() throws {
        for value in [String(repeating: "[{]}", count: 256), "\\\"[{}]", "\\\\\"[{}]", "literal \\u005b"] {
            let data = try JSONSerialization.data(withJSONObject: ["value": value])
            XCTAssertTrue(MCPJSONNesting.accepts(data))
        }
        let prefix = Data(("{\"quoted\":\"\\\\\",\"nested\":" + String(repeating: "[", count: 64)).utf8)
        XCTAssertFalse(MCPJSONNesting.accepts(prefix), "Backslash parity must end the string before counting nesting")
    }
    func testMalformedClosersFailClosedWithoutRecursiveParsing() {
        for value in ["]", "{]", "[}", "{}]"] { XCTAssertFalse(MCPJSONNesting.accepts(Data(value.utf8))) }
        XCTAssertTrue(MCPJSONNesting.accepts(Data("{\"unterminated".utf8)), "Syntax validation remains the SDK's job")
    }
    func testFragmentedOverdeepLineNeverReachesCompatibilityParser() async throws {
        let input = Pipe(), output = Pipe()
        defer {
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        let transport = BoundedMCPTransport(input: input.fileHandleForReading.fileDescriptor, output: output.fileHandleForWriting.fileDescriptor)
        try await transport.connect()
        let finished = expectation(description: "Deep fragmented stream closes")
        let reader = Task { () throws -> [Data] in
            defer { finished.fulfill() }
            var lines: [Data] = []
            for try await line in await transport.receive() { lines.append(line) }
            return lines
        }
        let data = Data(("{\"method\":\"initialize\",\"params\":{\"capabilities\":{\"experimental\":" + String(repeating: "[", count: 63) + "0" + String(repeating: "]", count: 63) + "}}}\n").utf8)
        for index in stride(from: 0, to: data.count, by: 7) {
            try input.fileHandleForWriting.write(contentsOf: data[index..<min(index + 7, data.count)])
        }
        try input.fileHandleForWriting.close()
        await fulfillment(of: [finished], timeout: 3)
        await transport.disconnect()
        let lines = try await reader.value
        XCTAssertTrue(lines.isEmpty)
    }
}
