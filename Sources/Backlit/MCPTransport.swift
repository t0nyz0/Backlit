import Foundation
import MCP
import Darwin

/// The pinned SDK models experimental client capabilities as String values,
/// although real clients send capability objects. Backlit implements none of
/// those extensions, so ignore this optional object before SDK initialization.
/// Leave invalid types and every other request field for the SDK to validate.
enum SDKInitializeCompatibility {
    static func messageForSDK(_ data: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              request["method"] as? String == "initialize",
              var params = request["params"] as? [String:Any],
              var capabilities = params["capabilities"] as? [String:Any],
              capabilities["experimental"] is [String:Any] else { return data }
        capabilities.removeValue(forKey:"experimental")
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject:request)) ?? data
    }
}

/// Event-driven stdio: no idle polling, bounded lines/queue, and no content
/// logging. This process never owns light hardware or a recovery lease.
actor BoundedMCPTransport: Transport {
    nonisolated let logger = StdioTransport().logger // SDK's no-op logger
    private let input: Int32
    private let output: Int32
    private var source: DispatchSourceRead?
    private var pending = Data()
    private var connected = false
    private var writing = false
    private var pendingSends = 0
    private static let maximumPendingSends = 8
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    static let maximumMessageBytes = 16_384

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input; self.output = output
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy:.bufferingOldest(8))
        stream = pair.stream; continuation = pair.continuation
    }
    func connect() throws {
        guard !connected else { return }
        for descriptor in [input, output] {
            let flags = fcntl(descriptor,F_GETFL)
            guard flags >= 0, fcntl(descriptor,F_SETFL,flags | O_NONBLOCK) >= 0 else {
                throw ExternalControlError(.unavailable, "MCP standard streams are unavailable.")
            }
        }
        connected = true
        let reader = DispatchSource.makeReadSource(fileDescriptor:input,queue:.global(qos:.utility))
        reader.setEventHandler { [weak self] in
            // One read task at a time, including when the actor is busy sending.
            reader.suspend()
            Task {
                await self?.readReady()
                reader.resume()
            }
        }
        source = reader; reader.resume()
    }
    private func readReady() {
        guard connected else { return }
        var bytes = [UInt8](repeating:0,count:4096)
        let count = Darwin.read(input,&bytes,bytes.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { finish(); return }
        pending.append(contentsOf:bytes.prefix(count))
        while let newline = pending.firstIndex(of:10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard line.count <= Self.maximumMessageBytes else { finish(); return }
            if !line.isEmpty, case .dropped = continuation.yield(SDKInitializeCompatibility.messageForSDK(line)) { finish(); return }
        }
        if pending.count > Self.maximumMessageBytes { finish() }
    }
    func receive() -> AsyncThrowingStream<Data, Error> { stream }
    func disconnect() { finish() }
    private func finish() {
        connected = false
        source?.setEventHandler {}; source?.cancel(); source = nil
        pending.removeAll(); continuation.finish()
    }
    func send(_ data: Data) async throws {
        guard connected, data.count <= 65_536 else {
            throw ExternalControlError(.unavailable, "MCP connection closed.")
        }
        // The SDK consumes input into independent request/response tasks.
        // Bound slow-reader output pressure as well as the input stream; do
        // not infer request lifetimes from IDs or cancellation notifications.
        guard pendingSends < Self.maximumPendingSends else {
            finish(); throw ExternalControlError(.busy, "MCP output is busy.")
        }
        pendingSends += 1
        defer { pendingSends -= 1 }
        var message = data; message.append(10)
        var offset = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while writing {
            guard connected, ProcessInfo.processInfo.systemUptime < deadline else {
                throw ExternalControlError(.busy, "MCP output is busy.")
            }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        writing = true; defer { writing = false }
        while offset < message.count {
            guard connected else { throw ExternalControlError(.unavailable, "MCP connection closed.") }
            let count = message.withUnsafeBytes { buffer in
                Darwin.write(output,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
            }
            if count > 0 { offset += count; continue }
            guard count < 0, errno == EAGAIN || errno == EINTR,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                finish(); throw ExternalControlError(.unavailable, "MCP output is unavailable.")
            }
            try await Task.sleep(nanoseconds:10_000_000)
        }
    }
}
