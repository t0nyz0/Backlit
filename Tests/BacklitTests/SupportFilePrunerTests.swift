import XCTest
@testable import Backlit

final class SupportFilePrunerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("backlit-prune-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    @discardableResult private func file(_ name: String, age: TimeInterval = 0, now: Date = Date(), contents: Data = Data("{}".utf8)) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }
    private func names() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    func testOnlyAgentEventsOlderThanAnHourAreRemoved() throws {
        let now = Date()
        try file("fresh.json", age: 10, now: now)
        try file("ignored-by-reader.json", age: 1200, now: now)
        try file("stale.json", age: 3700, now: now)
        try file("stale.txt", age: 99999, now: now)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: true)
        XCTAssertEqual(SupportFilePruner.pruneAgentEvents(directory: directory, now: now), 1)
        XCTAssertEqual(names(), ["fresh.json", "ignored-by-reader.json", "stale.txt", "folder.json"])
    }

    func testAgentEventPruningRefusesAWindowShorterThanTheReaders() throws {
        let now = Date()
        try file("recent.json", age: 600, now: now)
        XCTAssertEqual(SupportFilePruner.pruneAgentEvents(directory: directory, now: now, maximumAge: 60), 0)
        XCTAssertEqual(SupportFilePruner.pruneAgentEvents(directory: directory, now: now, maximumAge: .nan), 0)
        XCTAssertEqual(names(), ["recent.json"])
    }

    func testLiveEventReaderIsUnaffectedByPruning() throws {
        let events = directory.appendingPathComponent("agent-events")
        try AgentBridge.receive(agent: .claude, state: "working", session: "live-session", directory: events)
        XCTAssertEqual(SupportFilePruner.pruneAgentEvents(directory: events), 0)
        XCTAssertEqual(AgentBridge.events(directory: events).map(\.state), [.working])
    }

    func testOnlyTheNewestAgentBackupsAreKept() throws {
        let now = Date()
        for index in 0..<8 { try file("agent-backup-\(index).json", age: Double(index) * 60, now: now) }
        try file("agent-backup-notes.txt", age: 999999, now: now)
        try file("logo-recovery.json", age: 999999, now: now)
        XCTAssertEqual(SupportFilePruner.pruneAgentBackups(directory: directory, keep: 5), 3)
        XCTAssertEqual(names(), Set((0..<5).map { "agent-backup-\($0).json" } + ["agent-backup-notes.txt", "logo-recovery.json"]))
        XCTAssertEqual(SupportFilePruner.pruneAgentBackups(directory: directory, keep: 0), 0, "A non-positive limit must not delete everything")
    }

    func testLidTimersForOtherChoicesAreRemovedAndTheCurrentOneKept() throws {
        let current = UUID(), old = UUID()
        try file("lid-timer-\(current.uuidString).json")
        try file("lid-timer-\(old.uuidString).json")
        try file("lid-timer-not-a-uuid.json")
        try file("lid-recovery.json")
        XCTAssertEqual(SupportFilePruner.pruneLidTimers(directory: directory, keeping: current), 1)
        XCTAssertEqual(names(), ["lid-timer-\(current.uuidString).json", "lid-timer-not-a-uuid.json", "lid-recovery.json"])
        XCTAssertEqual(SupportFilePruner.pruneLidTimers(directory: directory, keeping: nil), 1)
        XCTAssertFalse(names().contains("lid-timer-\(current.uuidString).json"))
    }

    func testOrphanFadeLeasesAreRemovedWhenNoJournalExists() throws {
        let a = UUID(), b = UUID()
        try file("fade-lease-\(a.uuidString)", contents: Data())
        try file("fade-lease-\(b.uuidString)", contents: Data())
        try file("fade-lease-not-a-uuid", contents: Data())
        try file("lid-lease-\(UUID().uuidString)", contents: Data())
        XCTAssertEqual(SupportFilePruner.pruneFadeLeases(directory: directory), 2)
        XCTAssertFalse(names().contains("fade-lease-\(a.uuidString)"))
        XCTAssertTrue(names().contains("fade-lease-not-a-uuid"))
        XCTAssertEqual(names().filter { $0.hasPrefix("lid-lease-") }.count, 1)
    }

    func testTheJournalOwnersLeaseSurvivesAndTheJournalIsUntouched() throws {
        let owner = UUID(), orphan = UUID()
        let record = FadeRecoveryRecord(token: owner, parentPID: 1,
            originalContext: .init(lidClosed: false, sleeping: false, locked: false, generation: 1),
            keyboardStates: [1: 2], watchdogPID: nil, effectsAllowed: false, pendingBatch: nil, closedLidRequested: false)
        let journal = try JSONEncoder().encode(record)
        try file("fade-recovery.json", contents: journal)
        try file("fade-lease-\(owner.uuidString)", contents: Data())
        try file("fade-lease-\(orphan.uuidString)", contents: Data())
        XCTAssertEqual(SupportFilePruner.pruneFadeLeases(directory: directory), 1)
        XCTAssertTrue(names().contains("fade-lease-\(owner.uuidString)"))
        XCTAssertFalse(names().contains("fade-lease-\(orphan.uuidString)"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fade-recovery.json")), journal)
    }

    func testUnreadableJournalOrAnotherOwnerPreventsAnyLeaseRemoval() throws {
        let lease = UUID()
        try file("fade-lease-\(lease.uuidString)", contents: Data())
        try file("fade-recovery.json", contents: Data("not json".utf8))
        XCTAssertEqual(SupportFilePruner.pruneFadeLeases(directory: directory), 0, "Unknown ownership: touch nothing")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("fade-recovery.json"))
        // Another live owner of the logo lock means its leases are not ours to judge.
        let other = try FileLease(url: directory.appendingPathComponent("logo.lock"))
        XCTAssertEqual(withExtendedLifetime(other) { SupportFilePruner.pruneFadeLeases(directory: directory) }, 0)
        XCTAssertTrue(names().contains("fade-lease-\(lease.uuidString)"))
    }

    func testPrivateInterfaceRequiresTheExactTypeEncoding() {
        let text = NSString(string: "backlit")
        let length = NSSelectorFromString("length")
        XCTAssertTrue(PrivateInterface.matches(text, length, "Q16@0:8"))
        XCTAssertFalse(PrivateInterface.matches(text, length, "@16@0:8"), "Same selector, different return type")
        XCTAssertFalse(PrivateInterface.matches(text, NSSelectorFromString("backlitDoesNotExist:"), "v24@0:8@16"))
    }
}
