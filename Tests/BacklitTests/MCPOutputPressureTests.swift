import XCTest
import Darwin
@testable import Backlit

/// Real pipes, no GUI/backend/Keychain or existing application connection.
final class MCPOutputPressureTests: XCTestCase {
    private struct Fixture {
        let input: Pipe
        let output: Pipe
        let transport: BoundedMCPTransport

        init() {
            let input = Pipe(), output = Pipe()
            self.input = input; self.output = output
            transport = BoundedMCPTransport(input: input.fileHandleForReading.fileDescriptor,
                                            output: output.fileHandleForWriting.fileDescriptor)
        }
        func close() {
            try? input.fileHandleForReading.close(); try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
        }
        func makeOutputReaderNonblocking() throws {
            let fd = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw FixtureError.pipeFlags
            }
        }
        func fillOutput() throws {
            let chunk = [UInt8](repeating: 88, count: 4096)
            var total = 0
            while total <= 1_048_576 {
                let count = chunk.withUnsafeBytes { Darwin.write(output.fileHandleForWriting.fileDescriptor, $0.baseAddress!, $0.count) }
                if count > 0 { total += count; continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                if count < 0, errno == EINTR { continue }
                throw FixtureError.fill
            }
            throw FixtureError.unexpectedCapacity
        }
        func readAvailableOutput() throws -> Data {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
                if count > 0 { data.append(contentsOf: chunk.prefix(count)); continue }
                if count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { return data }
                if count < 0, errno == EINTR { continue }
                throw FixtureError.read
            }
        }
    }
    private enum FixtureError: Error { case pipeFlags, fill, unexpectedCapacity, read, readTimedOut }

    func testOutputPressureClosesStreamBeforeSlowWriterTimeout() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        try await fixture.transport.connect()
        try fixture.fillOutput()
        let closed = expectation(description: "Output pressure closes input stream")
        let reader = Task {
            for try await _ in await fixture.transport.receive() {}
            closed.fulfill()
        }
        // Eight pending sends are supported; a ninth must terminate pressure.
        // The old implementation leaves all nine queued until its 2s timeout.
        let sends = (0..<9).map { _ in Task {
            do { try await fixture.transport.send(Data("{}".utf8)); return false }
            catch { return true }
        } }
        await fulfillment(of: [closed], timeout: 1)
        await fixture.transport.disconnect()
        try await reader.value
        for send in sends { let failed = await send.value; XCTAssertTrue(failed) }
    }

    func testCancelledSendsReleasePressureAndConnectionCanBeReused() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        try await fixture.transport.connect()
        try fixture.makeOutputReaderNonblocking()
        try fixture.fillOutput()
        // More than the pending-send allowance, one cancellation at a time.
        for _ in 0..<12 {
            let blocked = Task { try await fixture.transport.send(Data("{}".utf8)) }
            try await Task.sleep(nanoseconds: 10_000_000)
            blocked.cancel()
            do { try await blocked.value; XCTFail("Full pipe unexpectedly accepted a send") }
            catch is CancellationError {}
            catch { XCTFail("Cancellation leaked pressure or closed connection: \(error)") }
        }
        _ = try fixture.readAvailableOutput()
        try await fixture.transport.send(Data("{\"result\":{}}".utf8))
        XCTAssertEqual(try fixture.readAvailableOutput(), Data("{\"result\":{}}\n".utf8))
        await fixture.transport.disconnect()
    }

    func testHealthyConsumedOutputDelivers1024Messages() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        try await fixture.transport.connect()
        try fixture.makeOutputReaderNonblocking()
        let message = Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}".utf8)
        let expected = (0..<1024).reduce(into: Data()) { data, _ in data.append(message); data.append(10) }
        let reader = Task { () throws -> Data in
            var data = Data()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while data.count < expected.count {
                data.append(try fixture.readAvailableOutput())
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.readTimedOut }
                if data.count < expected.count { try await Task.sleep(nanoseconds: 1_000_000) }
            }
            return data
        }
        for _ in 0..<1024 { try await fixture.transport.send(message) }
        let received = try await reader.value
        XCTAssertEqual(received, expected)
        await fixture.transport.disconnect()
    }

    func testNotificationAndInvalidIDInputRemainUnmodified() async throws {
        let fixture = Fixture(); defer { fixture.close() }
        try await fixture.transport.connect()
        let lines = [
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"unknown"}}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1.25,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#
        ].map { Data($0.utf8) }
        let reader = Task { () throws -> [Data] in
            var received: [Data] = []
            for try await line in await fixture.transport.receive() { received.append(line) }
            return received
        }
        for line in lines { try fixture.input.fileHandleForWriting.write(contentsOf: line + Data([10])) }
        try fixture.input.fileHandleForWriting.close()
        let received = try await reader.value
        XCTAssertEqual(received, lines)
        await fixture.transport.disconnect()
    }
}
