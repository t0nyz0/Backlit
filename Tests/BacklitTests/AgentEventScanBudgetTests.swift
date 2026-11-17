import XCTest
@testable import Backlit

final class AgentEventScanBudgetTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 500_000)
    private func payload(_ state: AgentState = .working, age: TimeInterval = 0) throws -> Data {
        try JSONEncoder().encode(AgentEvent(agent: .codex, state: state, time: now.addingTimeInterval(-age)))
    }
    private func scan(_ names: [String], entries: Int, reads: Int, data: Data) -> (AgentEventScan, [String], Int) {
        var index = 0, opened: [String] = [], nextCalls = 0
        let result = AgentBridge.scanEvents(now: now, limits: .init(maximumEntries: entries, maximumReads: reads), nextURL: {
            nextCalls += 1
            guard index < names.count else { return nil }
            defer { index += 1 }
            return URL(fileURLWithPath: "/inert-fixture/" + names[index])
        }, readMetadata: { file in opened.append(file.lastPathComponent); return data })
        return (result, opened, nextCalls)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testEntryBudgetBoundsEnumerationEvenWhenNoNamesAreMetadata() throws {
        let (result, opened, calls) = scan((0..<100).map { "ignored-\($0).txt" }, entries: 3, reads: 10, data: try payload())
        XCTAssertTrue(result.limited)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(calls, 4, "Only one extra entry may be peeked, without reading it")
    }
    func testReadBudgetDoesNotOpenOrDecodeTheNextMetadataEntry() throws {
        let (result, opened, calls) = scan(["first.json", "ignored.txt", "second.json", "third.json"], entries: 20, reads: 2, data: try payload())
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(opened, ["first.json", "second.json"])
        XCTAssertEqual(calls, 4)
    }
    func testExactlyFullBudgetsAreCompleteWhenDirectoryEnds() throws {
        let (result, opened, calls) = scan(["first.json", "second.json"], entries: 2, reads: 2, data: try payload())
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.events.count, 2)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(calls, 3)
    }
    func testUnreadIrrelevantTailDoesNotFalselyMarkReadBudgetLimited() throws {
        let (result, opened, _) = scan(["first.json", "notes.txt", "helper.tmp"], entries: 3, reads: 1, data: try payload())
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(opened, ["first.json"])
    }
    func testInvalidOrExpiredMetadataStillConsumesTheReadBudget() throws {
        for data in [Data("not JSON".utf8), try payload(age: 901), Data(repeating: 32, count: 4096)] {
            let (result, opened, _) = scan(["first.json", "second.json", "third.json"], entries: 10, reads: 2, data: data)
            XCTAssertTrue(result.limited)
            XCTAssertTrue(result.events.isEmpty)
            XCTAssertEqual(opened.count, 2)
        }
    }
    func testZeroOrNegativeBudgetsCannotCauseAnUnboundedScan() throws {
        for limit in [0, -1] {
            let (result, opened, calls) = scan(["first.json"], entries: limit, reads: limit, data: try payload())
            XCTAssertTrue(result.limited)
            XCTAssertTrue(opened.isEmpty)
            XCTAssertEqual(calls, 1)
            let (empty, _, _) = scan([], entries: limit, reads: limit, data: try payload())
            XCTAssertFalse(empty.limited)
        }
    }
    func testProductionCursorIsNonrecursiveAndLeavesFilesUntouched() throws {
        let directory = try temporaryDirectory(), data = try payload(.attention)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let journal = nested.appendingPathComponent("lid-recovery.json")
        try data.write(to: journal)
        for index in 0..<129 { try data.write(to: directory.appendingPathComponent("session-\(index).json")) }
        let result = AgentBridge.scanEvents(directory: directory, now: now)
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.events.count, 129, "Normal multi-session behavior remains complete")
        XCTAssertEqual(try Data(contentsOf: journal), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 130)
    }
    func testProductionCursorReportsExactLimitAndExtraEntryCorrectly() throws {
        let directory = try temporaryDirectory(), data = try payload()
        for index in 0..<2 { try data.write(to: directory.appendingPathComponent("session-\(index).json")) }
        let limits = AgentEventScanLimits(maximumEntries: 2, maximumReads: 2)
        let exact = AgentBridge.scanEvents(directory: directory, now: now, limits: limits)
        XCTAssertFalse(exact.limited)
        XCTAssertEqual(exact.events.count, 2)
        try data.write(to: directory.appendingPathComponent("extra.json"))
        let extra = AgentBridge.scanEvents(directory: directory, now: now, limits: limits)
        XCTAssertTrue(extra.limited)
        XCTAssertEqual(extra.events.count, 2)
    }
    func testProductionReadBudgetBoundsActualRegularFiles() throws {
        let directory = try temporaryDirectory(), data = try payload()
        for index in 0..<10 { try data.write(to: directory.appendingPathComponent("session-\(index).json")) }
        let result = AgentBridge.scanEvents(directory: directory, now: now, limits: .init(maximumEntries: 20, maximumReads: 3))
        XCTAssertTrue(result.limited)
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 10)
    }
    func testAbsentDirectoryIsEmptyButEnumerationFailureIsIncomplete() throws {
        let directory = try temporaryDirectory()
        let absent = AgentBridge.scanEvents(directory: directory.appendingPathComponent("absent"), now: now)
        XCTAssertTrue(absent.events.isEmpty)
        XCTAssertFalse(absent.limited)
        let regularFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: regularFile)
        let failed = AgentBridge.scanEvents(directory: regularFile, now: now)
        XCTAssertTrue(failed.events.isEmpty)
        XCTAssertTrue(failed.limited)
    }
}
