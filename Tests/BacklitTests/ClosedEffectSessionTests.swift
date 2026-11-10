import XCTest
@testable import Backlit
final class ClosedEffectSessionTests: XCTestCase {
    func testConcurrentFrameCannotEnterOwnedRestoreBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try ClosedEffectSession.locked(directory: directory, wait: false) {
            let other = try ClosedEffectSession.locked(directory: directory, wait: false) { XCTFail("Must not interleave"); return true }
            XCTAssertNil(other)
        }
        XCTAssertEqual(try ClosedEffectSession.locked(directory: directory, wait: false) { true }, true)
    }
    func testRevokedSessionCannotResumeAfterAcquiringLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("lid-recovery.json")
        try Data("{\"logoOverride\":true,\"effectsAllowed\":true}".utf8).write(to: journal)
        XCTAssertTrue(ClosedEffectSession.permitted(directory: directory))
        _ = try ClosedEffectSession.locked(directory: directory, wait: true) {
            try Data("{\"logoOverride\":true,\"effectsAllowed\":false}".utf8).write(to: journal)
            XCTAssertFalse(ClosedEffectSession.permitted(directory: directory))
        }
        _ = try ClosedEffectSession.locked(directory: directory, wait: false) { XCTAssertFalse(ClosedEffectSession.permitted(directory: directory)) }
    }
    func testMissingOrLegacyJournalDoesNotAuthorizeNewEffectWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(ClosedEffectSession.permitted(directory: directory))
        try Data("{\"logoOverride\":true}".utf8).write(to: directory.appendingPathComponent("lid-recovery.json"))
        XCTAssertFalse(ClosedEffectSession.permitted(directory: directory))
    }
    func testWaitingFrameObservesRevocationAfterCleanupReleasesLock() throws {
        final class Outcome: @unchecked Sendable { var permitted: Bool?; var failed = false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = directory.appendingPathComponent("lid-recovery.json")
        try Data("{\"logoOverride\":true,\"effectsAllowed\":true}".utf8).write(to: journal)
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0), outcome = Outcome()
        _ = try ClosedEffectSession.locked(directory: directory, wait: true) {
            DispatchQueue.global().async {
                started.signal()
                do {
                    outcome.permitted = try ClosedEffectSession.locked(directory: directory, wait: true) { ClosedEffectSession.permitted(directory: directory) }
                } catch { outcome.failed = true }
                finished.signal()
            }
            XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
            try Data("{\"logoOverride\":true,\"effectsAllowed\":false}".utf8).write(to: journal)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.03), .timedOut)
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(outcome.permitted, false)
    }
}
