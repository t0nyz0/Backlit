import Foundation
import XCTest
@testable import Backlit

final class LidSessionDurationTests: XCTestCase {
    func testDefaultAndMinuteHourConversions() {
        XCTAssertEqual(LidSessionDuration().durationSeconds, 1800)
        XCTAssertEqual(LidSessionDuration(amount: 1).durationSeconds, 60)
        XCTAssertEqual(LidSessionDuration(amount: 45).durationSeconds, 1800)
        XCTAssertEqual(LidSessionDuration(amount: 2, unit: .hours).durationSeconds, 1800)
        XCTAssertEqual(LidSessionDuration(amount: 10080).durationSeconds, 1800)
        XCTAssertEqual(LidSessionDuration(amount: 168, unit: .hours).durationSeconds, 1800)
    }

    func testTypedExtremesClampWithoutOverflowOrSelectingUnlimited() {
        for unit in LidDurationUnit.allCases {
            XCTAssertEqual(LidSessionDuration(amount: Int.min, unit: unit).amount, 1)
            XCTAssertEqual(LidSessionDuration(amount: 0, unit: unit).amount, 1)
            XCTAssertEqual(LidSessionDuration(amount: Int.max, unit: unit).amount, 30)
            XCTAssertEqual(LidSessionDuration(amount: Int.max, unit: unit).durationSeconds, 1800)
        }
    }

    func testLegacyUnlimitedNormalizesToThirtyMinutes() throws {
        let duration = LidSessionDuration(mode: .untilTurnedOff, amount: 3, unit: .hours)
        XCTAssertEqual(duration.durationSeconds, 1800)
        XCTAssertEqual(duration.amount, 30)
        XCTAssertEqual(duration.unit, .minutes)
        XCTAssertEqual(try JSONDecoder().decode(LidSessionDuration.self, from: JSONEncoder().encode(duration)), duration)
    }

    func testMalformedPreferencesFallBackToTimedThirtyMinutes() throws {
        let invalid = [
            "{}", "{\"mode\":\"untilTurnedOff\"}",
            "{\"mode\":\"unknown\",\"amount\":30,\"unit\":\"minutes\"}",
            "{\"mode\":\"untilTurnedOff\",\"amount\":0,\"unit\":\"minutes\"}",
            "{\"mode\":\"untilTurnedOff\",\"amount\":169,\"unit\":\"hours\"}",
            "{\"mode\":\"timed\",\"amount\":-20,\"unit\":\"minutes\"}",
            "{\"mode\":\"timed\",\"amount\":1.5,\"unit\":\"hours\"}",
            "{\"mode\":\"timed\",\"amount\":30,\"unit\":\"days\"}"
        ]
        for value in invalid {
            XCTAssertEqual(try JSONDecoder().decode(LidSessionDuration.self, from: Data(value.utf8)), LidSessionDuration())
        }
    }

    func testLegacyWatcherDefaultsAndExplicitDurationRoundTrip() throws {
        let lease = URL(fileURLWithPath: "/tmp/backlit session lease")
        let legacy = try XCTUnwrap(LidWatcherArguments(arguments: ["Backlit", "--watch-lid", "123", lease.path]))
        XCTAssertEqual(legacy.parent, 123)
        XCTAssertEqual(legacy.lease, lease)
        XCTAssertEqual(legacy.durationSeconds, 1800)
        for duration in [LidSessionDuration(), LidSessionDuration(amount: 8, unit: .hours),
                         LidSessionDuration(amount: 10080), LidSessionDuration(mode: .untilTurnedOff)] {
            let request = try XCTUnwrap(LidWatcherArguments(arguments: ["Backlit"] + duration.watcherArguments(parent: 123, lease: lease)))
            XCTAssertEqual(request.parent, 123)
            XCTAssertEqual(request.lease, lease)
            XCTAssertEqual(request.durationSeconds, duration.durationSeconds)
        }
        XCTAssertEqual(LidWatcherArguments(arguments: ["--watch-lid", "123", lease.path, "0.5"])?.durationSeconds, 0.5)
        let token = UUID(), duration = LidSessionDuration(amount: 2, unit: .hours)
        let retained = try XCTUnwrap(LidWatcherArguments(arguments: ["Backlit"] + duration.watcherArguments(parent: 123, lease: lease, intent: token)))
        XCTAssertEqual(retained.intent, token)
        XCTAssertEqual(retained.durationSeconds, 1800)
        XCTAssertNil(legacy.intent)
    }

    func testInvalidWatcherArgumentsAreRejected() {
        for values in [
            [], ["--watch-lid"], ["--watch-lid", "123"], ["--watch-lid", "123", ""],
            ["--watch-lid", "0", "/tmp/lease"], ["--watch-lid", "-1", "/tmp/lease"],
            ["--watch-lid", "2147483648", "/tmp/lease"], ["--watch-lid", "pid", "/tmp/lease"],
            ["--watch-lid", "123", "relative"], ["--watch-lid", "123", "/tmp/lease\0suffix"],
            ["--watch-lid", "123", "/tmp/lease", "nan"], ["--watch-lid", "123", "/tmp/lease", "inf"],
            ["--watch-lid", "123", "/tmp/lease", "-1"], ["--watch-lid", "123", "/tmp/lease", "604801"],
            ["--watch-lid", "123", "/tmp/lease", ""], ["--watch-lid", "123", "/tmp/lease", "1e300"],
            ["--watch-lid", "123", "/tmp/lease", "0"], ["--watch-lid", "123", "/tmp/lease", "1801"],
            ["--watch-lid", "123", "/tmp/lease", "1800", "extra"]
        ] {
            XCTAssertNil(LidWatcherArguments(arguments: values), "Unexpectedly accepted: \(values)")
        }
    }
}

@MainActor final class LidDurationPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "local.backlit.test.lid-duration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testPreferencePersistsButNeverStartsSessionAtLaunch() {
        let defaults = defaults()
        defaults.set(0.37, forKey: "brightness")
        defaults.set("keep", forKey: "unrelated.fixture")
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(model.lidSessionDuration, LidSessionDuration())
        model.setLidDuration(amount: 4, unit: .hours)
        model.setLidDuration(mode: .untilTurnedOff)
        XCTAssertFalse(model.keepClosed)
        XCTAssertTrue(model.prepareQuit())

        let reopened = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(reopened.lidSessionDuration, LidSessionDuration(mode: .untilTurnedOff, amount: 4, unit: .hours))
        XCTAssertFalse(reopened.keepClosed)
        XCTAssertEqual(reopened.brightness, 0.37)
        XCTAssertEqual(defaults.string(forKey: "unrelated.fixture"), "keep")
        reopened.setLidDuration(mode: .timed)
        XCTAssertEqual(reopened.lidSessionDuration.durationSeconds, 1800)
        XCTAssertTrue(reopened.prepareQuit())
    }

    func testModelNormalizesNumericAndUnitEdits() {
        let model = AppModel(demo: true, defaults: defaults())
        model.setLidDuration(amount: 10080)
        model.setLidDuration(unit: .hours)
        XCTAssertEqual(model.lidSessionDuration.amount, 30)
        model.setLidDuration(amount: 0)
        XCTAssertEqual(model.lidSessionDuration.durationSeconds, 60)
        model.setLidDuration(amount: 2, unit: .minutes)
        XCTAssertEqual(model.lidSessionDuration.durationSeconds, 120)
        XCTAssertTrue(model.prepareQuit())
    }

    func testMalformedStoredDataCannotEnableAnUnlimitedSession() {
        let defaults = defaults()
        for invalid in [Data([0, 255]), Data("{\"mode\":\"untilTurnedOff\"}".utf8)] {
            defaults.set(invalid, forKey: LidSessionDuration.preferenceKey)
            let model = AppModel(demo: true, defaults: defaults)
            XCTAssertEqual(model.lidSessionDuration, LidSessionDuration())
            XCTAssertFalse(model.keepClosed)
            XCTAssertTrue(model.prepareQuit())
        }
    }

    func testActiveAndStoppingSessionKeepTheirOriginalDuration() async {
        final class Watcher: LidWatcherProcess {
            var isRunning = true
            var terminationStatus: Int32 = 0
            func terminate() { isRunning = false }
        }
        let stopper = LidWatcherStopper(timeout: 1, pollInterval: 0.01, removeLease: { _ in }, needsRecovery: { _ in false })
        let model = AppModel(demo: true, defaults: defaults(), lidStopper: stopper)
        let watcher = Watcher()
        model.setLidDuration(amount: 2, unit: .hours)
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/inert-duration-lease")))
        XCTAssertFalse(model.canEditLidDuration)
        model.setLidDuration(mode: .untilTurnedOff)
        XCTAssertEqual(model.lidSessionDuration.durationSeconds, 1800)
        let stopped = expectation(description: "Inert cleanup completed")
        model.onLidStopCompleted = { safe in XCTAssertTrue(safe); stopped.fulfill() }
        model.stopLid()
        XCTAssertTrue(model.lidStopPending)
        model.setLidDuration(amount: 9)
        XCTAssertEqual(model.lidSessionDuration.amount, 30)
        watcher.isRunning = false
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertTrue(model.canEditLidDuration)
        model.setLidDuration(mode: .untilTurnedOff)
        XCTAssertEqual(model.lidSessionDuration.durationSeconds, 1800)
        XCTAssertTrue(model.prepareQuit())
    }
}
