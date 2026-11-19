import XCTest
import Darwin
@testable import Backlit

final class AgentEventFileTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func payload(at time: Date) throws -> Data {
        try JSONEncoder().encode(AgentEvent(agent: .codex, state: .working, time: time))
    }

    func testEventsRejectSymbolicLinksEvenWhenTheirTargetsContainValidMetadata() throws {
        let directory = try temporaryDirectory(), now = Date()
        let events = directory.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("outside-metadata")
        let original = try payload(at: now)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: events.appendingPathComponent("linked.json"), withDestinationURL: target)
        XCTAssertTrue(AgentBridge.events(directory: events, now: now).isEmpty)
        XCTAssertEqual(try Data(contentsOf: target), original, "Inspection must not alter the target")
    }

    func testMetadataReadBoundaryPreservesTheExistingStrictFourKiBLimit() throws {
        let directory = try temporaryDirectory(), now = Date(), data = try payload(at: now)
        XCTAssertLessThan(data.count, 4095)
        for size in [4095, 4096, 4097, 1_048_576] {
            var padded = data
            padded.append(Data(repeating: 32, count: size - data.count))
            try padded.write(to: directory.appendingPathComponent("boundary.json"), options: .atomic)
            XCTAssertEqual(AgentBridge.events(directory: directory, now: now).count, size == 4095 ? 1 : 0)
        }
    }

    func testEventsIgnoreDirectoriesMalformedFilesAndNonJSONFiles() throws {
        let directory = try temporaryDirectory(), now = Date()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("bad.json"))
        try payload(at: now).write(to: directory.appendingPathComponent("ignored.txt"))
        XCTAssertTrue(AgentBridge.events(directory: directory, now: now).isEmpty)
    }

    func testBoundedPerFileReadsDoNotSilentlyLimitValidSessions() throws {
        let directory = try temporaryDirectory(), now = Date()
        for index in 0..<129 {
            try payload(at: now).write(to: directory.appendingPathComponent("session-\(index).json"))
        }
        XCTAssertEqual(AgentBridge.events(directory: directory, now: now).count, 129)
    }
}

// Run against the patched reader only: the old Data(contentsOf:) path can block
// opening a FIFO. This fixture is confined to its own disposable directory.
final class AgentEventSpecialFileTests: XCTestCase {
    func testEventsRejectFIFOWithoutWaitingForAWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("pipe.json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(AgentBridge.events(directory: directory).isEmpty)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }
}
