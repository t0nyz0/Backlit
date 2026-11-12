import XCTest
@testable import Backlit

final class LidThirtyMinuteCapTests: XCTestCase {
    func intent(_ seconds: Double, id: UUID = UUID(), blocked: Bool = false) throws -> LidSessionIntent {
        let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id.uuidString,
            "durationSeconds": seconds, "blocked": blocked])
        return try JSONDecoder().decode(LidSessionIntent.self, from: bytes)
    }
    func testLegacyPreferencesNormalizeWithoutHoursRangeTrapOrOverflow() throws {
        for (mode, amount, unit) in [("untilTurnedOff", 1, "minutes"), ("timed", 45, "minutes"),
                                     ("timed", 1, "hours"), ("timed", Int.max, "hours")] {
            let data = try JSONSerialization.data(withJSONObject: ["mode": mode, "amount": amount, "unit": unit])
            let value = try JSONDecoder().decode(LidSessionDuration.self, from: data)
            XCTAssertEqual(value.durationSeconds, 1800); XCTAssertEqual(value.unit, .minutes); XCTAssertEqual(value.mode, .timed)
        }
    }
    func testLongCheckpointKeepsOriginalStartAndShortensRemainingTime() throws {
        let id = UUID(), boot = UUID(), value = try intent(7200, id: id)
        let old = LidTimerCheckpoint(version: 1, intent: id, boot: boot, duration: 7200, closedAt: 100, deadline: 7300)
        for now in [700.0, 1200, 1899] {
            guard case let .ready(capped?) = LidIntentPolicy.timer(intent: value, checkpoint: old, clock: .init(boot: boot, seconds: now), closed: true) else { return XCTFail("Still within original capped deadline") }
            XCTAssertEqual(capped.closedAt, 100); XCTAssertEqual(capped.deadline, 1900); XCTAssertEqual(capped.duration, 1800)
        }
        for now in [1900.0, 1960, 7301] {
            XCTAssertEqual(LidIntentPolicy.timer(intent: value, checkpoint: old, clock: .init(boot: boot, seconds: now), closed: true), .expired)
        }
    }
    func testMigrationRejectsCorruptAndWrongBootCheckpoints() throws {
        let id = UUID(), boot = UUID(), value = try intent(7200, id: id), clock = LidContinuousClock(boot: boot, seconds: 700)
        for old in [LidTimerCheckpoint(version: 1, intent: id, boot: boot, duration: 7200, closedAt: 100, deadline: 9999),
                    .init(version: 1, intent: id, boot: UUID(), duration: 7200, closedAt: 100, deadline: 7300),
                    .init(version: 1, intent: UUID(), boot: boot, duration: 7200, closedAt: 100, deadline: 7300)] {
            XCTAssertEqual(LidIntentPolicy.timer(intent: value, checkpoint: old, clock: clock, closed: true), .needsOpen)
        }
    }
    func testUnlimitedUpgradeCannotInventStartWhileClosed() throws {
        let value = try intent(0), clock = LidContinuousClock(boot: UUID(), seconds: 5000)
        XCTAssertEqual(value.durationSeconds, 1800)
        XCTAssertEqual(LidIntentPolicy.timer(intent: value, checkpoint: nil, clock: clock, closed: true), .needsOpen)
        guard case .ready = LidIntentPolicy.timer(intent: value, checkpoint: nil, clock: clock, closed: false) else { return XCTFail("A verified open can prepare a new cycle") }
    }
    func testCappedCheckpointMustPersistBeforeGrant() throws {
        let id = UUID(), boot = UUID(), value = try intent(7200, id: id)
        let old = LidTimerCheckpoint(version: 1, intent: id, boot: boot, duration: 7200, closedAt: 100, deadline: 7300)
        let monitor = LidTimerMonitor(intent: value, read: { old }, write: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try monitor.update(closed: true, clock: .init(boot: boot, seconds: 700)))
    }
    func testRelaunchAndSleepCannotExtendCappedDeadline() throws {
        let id = UUID(), boot = UUID(), value = try intent(7200, id: id)
        var saved = LidTimerCheckpoint(version: 1, intent: id, boot: boot, duration: 7200, closedAt: 100, deadline: 7300)
        let first = LidTimerMonitor(intent: value, read: { saved }, write: { saved = $0 })
        XCTAssertTrue(try first.update(closed: true, clock: .init(boot: boot, seconds: 700)))
        let relaunched = LidTimerMonitor(intent: value, read: { saved }, write: { saved = $0 })
        XCTAssertFalse(try relaunched.update(closed: true, clock: .init(boot: boot, seconds: 2000)))
        XCTAssertEqual(saved.deadline, 1900)
    }
    func testLegacyHelperCountsSleepAndRejectsClockFailureUntilOpen() {
        let boot = UUID()
        var timer = LidLegacyContinuousTimer(duration: 1800)
        XCTAssertTrue(timer.permits(closed: true, clock: .init(boot: boot, seconds: 100)))
        XCTAssertFalse(timer.permits(closed: true, clock: .init(boot: boot, seconds: 1900)))
        XCTAssertFalse(timer.permits(closed: true, clock: .init(boot: boot, seconds: 2000)))
        XCTAssertTrue(timer.permits(closed: false, clock: .init(boot: boot, seconds: 2000)))
        XCTAssertTrue(timer.permits(closed: true, clock: .init(boot: boot, seconds: 2100)))
        XCTAssertFalse(timer.permits(closed: true, clock: nil))
        XCTAssertFalse(timer.permits(closed: true, clock: .init(boot: boot, seconds: 2200)))
    }
    func testLegacyHelperRejectsClockRegressionAndBootChange() {
        for changed in [LidContinuousClock(boot: UUID(), seconds: 150), .init(boot: UUID(), seconds: 50)] {
            var timer = LidLegacyContinuousTimer(duration: 1800)
            XCTAssertTrue(timer.permits(closed: true, clock: .init(boot: changed.boot, seconds: 100)))
            let next = changed.seconds == 150 ? LidContinuousClock(boot: UUID(), seconds: 150) : changed
            XCTAssertFalse(timer.permits(closed: true, clock: next))
            XCTAssertFalse(timer.permits(closed: true, clock: .init(boot: changed.boot, seconds: 200)))
        }
    }
    @MainActor func testStoredMigrationPreservesFaultAndUnrelatedSettings() throws {
        let suite = "Backlit.Cap." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), boot = UUID()
        let raw: [String: Any] = ["version": 1, "id": id.uuidString, "durationSeconds": 0, "blocked": true,
            "pause": ["reason": "hardFault", "attempts": 2, "retryBoot": boot.uuidString, "retryAfter": 1234, "detail": "Preserve me"]]
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: LidSessionIntent.preferenceKey)
        defaults.set(0.42, forKey: "brightness")
        LidSessionIntent.migrateStoredDuration(defaults)
        let value = try XCTUnwrap(LidSessionIntent.load(defaults))
        XCTAssertEqual(value.id, id); XCTAssertEqual(value.durationSeconds, 1800); XCTAssertTrue(value.blocked)
        XCTAssertEqual(value.pause?.reason, .hardFault); XCTAssertEqual(value.pause?.attempts, 2)
        XCTAssertEqual(value.pause?.retryBoot, boot); XCTAssertEqual(value.pause?.retryAfter, 1234)
        XCTAssertEqual(value.pause?.detail, "Preserve me"); XCTAssertEqual(defaults.double(forKey: "brightness"), 0.42)
        let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: LidSessionIntent.preferenceKey)!) as! [String: Any]
        XCTAssertEqual(saved["durationSeconds"] as? Int, 1800)
    }
}
