import XCTest
@testable import Backlit

final class FadeRuntimeRestoreRetryTests: XCTestCase {
    /// Only injected closures and a temporary recovery directory are used.
    /// No live adapter, client, helper process or app is created.
    private final class Fixture {
        let directory: URL
        let store: FadeRecoveryStore
        let token: UUID
        var context: FadeSafetyContext? = .init(lidClosed: false, sleeping: false, locked: false, generation: 1)
        var terminalFactor: Double? = 0.5
        var now = 0.0
        var events: [String] = []
        var rejected: String?
        var hadWriteFailure = false

        lazy var hardware = LiveFadeHardware(interface: .init(
            context: { self.context }, keyboardIDs: { [7] },
            keyboardState: { _ in NSNumber(value: 2) },
            duration: { self.write("recovery:duration:\($0)") },
            logicalState: { self.write("recovery:global:\($0)") },
            keyboardLogicalState: { self.write("keyboard:\($0):\($1)") },
            keyboardClosed: { self.write("closed:\($0)") },
            factor: { self.terminalFactor }, logoEnabled: { false },
            now: { self.now }, wait: { self.now += $0 }))
        lazy var effect = ClosedLidEffect(interface: .init(
            sample: { .init(factor: 0.5, appliedNits: 100, multiplier: 1) },
            duration: { self.write("effect:duration:\($0)") },
            logicalState: { self.write("effect:global:\($0)") },
            keepKeyboardDark: { true }, now: { self.now }))

        init(pending: Bool = true) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = FadeRecoveryStore(directory: directory)
            let context = FadeSafetyContext(lidClosed: false, sleeping: false, locked: false, generation: 1)
            token = try store.prepare(parentPID: 123, context: context, keyboards: [7: 2])
            try store.acknowledgeWatchdog(token: token, watchdogPID: 456, parentAlive: { _ in true })
            if pending {
                _ = try store.withPermission(token: token, watchdogAlive: { $0 == 456 },
                    snapshot: .init(context: context, keyboardStates: [7: 2])) {
                    try hardware.guardedFadeWrite { try effect.execute(effect.plan(0.25)) }
                }
            }
            events.removeAll()
        }

        func write(_ event: String) -> Bool {
            events.append(event)
            return event != rejected
        }

        func restore() throws {
            try store.recover(token: token) { record in
                try FadeRuntime.restore(record, hardware: hardware, effect: effect, hadWriteFailure: hadWriteFailure) {
                    self.hadWriteFailure = true
                }
            }
        }

        func assertPending(file: StaticString = #filePath, line: UInt = #line) throws {
            let record = try store.read()
            XCTAssertEqual(record.token, token, file: file, line: line)
            XCTAssertNotNil(record.pendingBatch, file: file, line: line)
            XCTAssertFalse(record.effectsAllowed, file: file, line: line)
            XCTAssertFalse(store.completed(token: token), file: file, line: line)
        }

        func assertCompleted(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path), file: file, line: line)
            XCTAssertTrue(store.completed(token: token), file: file, line: line)
        }
    }

    private func fixture(pending: Bool = true) throws -> Fixture {
        let fixture = try Fixture(pending: pending)
        addTeardownBlock { try FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }

    private let healthyReset = ["effect:duration:5.0", "effect:global:1", "effect:duration:0.0", "effect:global:2", "keyboard:7:2"]
    private let conservativeReset = ["recovery:duration:5.0", "recovery:global:1", "recovery:duration:0.0", "recovery:global:2", "keyboard:7:1"]

    func testUnconfirmedHealthyResetRetriesInactiveEffectThroughConservativeReset() throws {
        let fixture = try fixture()
        XCTAssertTrue(fixture.effect.active)
        fixture.terminalFactor = nil

        XCTAssertThrowsError(try fixture.restore())
        XCTAssertEqual(fixture.events, healthyReset)
        XCTAssertFalse(fixture.effect.active, "All effect setters returned true before the terminal read failed")
        XCTAssertTrue(fixture.hadWriteFailure)
        try fixture.assertPending()

        fixture.events.removeAll()
        fixture.terminalFactor = 1
        try fixture.restore()
        XCTAssertEqual(fixture.events, conservativeReset, "Retry must issue a reset even though the effect is inactive")
        fixture.assertCompleted()
    }

    func testRepeatedUnconfirmedResetsRetainJournalUntilFinalSuccessfulRetry() throws {
        let fixture = try fixture()
        // Every injected setter returns true, but the factor never reaches an endpoint.
        XCTAssertThrowsError(try fixture.restore())
        XCTAssertEqual(fixture.events, healthyReset)
        XCTAssertFalse(fixture.effect.active)
        try fixture.assertPending()

        fixture.events.removeAll()
        XCTAssertThrowsError(try fixture.restore())
        XCTAssertEqual(fixture.events, conservativeReset)
        try fixture.assertPending()

        fixture.events.removeAll()
        fixture.terminalFactor = 0
        try fixture.restore()
        XCTAssertEqual(fixture.events, conservativeReset)
        fixture.assertCompleted()
    }

    func testFailedKeyboardHandbackAlsoLatchesConservativeRetry() throws {
        let fixture = try fixture()
        fixture.terminalFactor = 1
        fixture.rejected = "keyboard:7:2"
        XCTAssertThrowsError(try fixture.restore())
        XCTAssertEqual(fixture.events, healthyReset)
        XCTAssertFalse(fixture.effect.active)
        XCTAssertTrue(fixture.hadWriteFailure)
        try fixture.assertPending()

        fixture.events.removeAll()
        fixture.rejected = nil
        try fixture.restore()
        XCTAssertEqual(fixture.events, conservativeReset)
        fixture.assertCompleted()
    }

    func testRetryAfterSafetyTransitionNeverUnblanks() throws {
        let contexts: [FadeSafetyContext] = [
            .init(lidClosed: true, sleeping: false, locked: false, generation: 2),
            .init(lidClosed: false, sleeping: true, locked: false, generation: 2),
            .init(lidClosed: false, sleeping: false, locked: true, generation: 2)
        ]
        for context in contexts {
            let fixture = try fixture()
            fixture.terminalFactor = nil
            XCTAssertThrowsError(try fixture.restore())
            try fixture.assertPending()

            fixture.context = context
            fixture.terminalFactor = 0
            fixture.events.removeAll()
            try fixture.restore()
            XCTAssertEqual(fixture.events, ["recovery:duration:0.0", "recovery:global:1",
                context.lidClosed ? "closed:7" : "keyboard:7:1"])
            fixture.assertCompleted()
        }
    }

    func testUnknownRetryContextMakesNoWritesAndRetainsJournal() throws {
        let fixture = try fixture()
        fixture.terminalFactor = nil
        XCTAssertThrowsError(try fixture.restore())
        fixture.events.removeAll()
        fixture.context = nil
        XCTAssertThrowsError(try fixture.restore())
        XCTAssertTrue(fixture.events.isEmpty)
        try fixture.assertPending()

        fixture.context = .init(lidClosed: false, sleeping: false, locked: false, generation: 2)
        fixture.terminalFactor = 1
        try fixture.restore()
        XCTAssertEqual(fixture.events, conservativeReset)
        fixture.assertCompleted()
    }

    func testPriorFrameWriteFailureUsesConservativeResetImmediately() throws {
        let fixture = try fixture()
        fixture.hadWriteFailure = true
        fixture.terminalFactor = 1
        try fixture.restore()
        XCTAssertEqual(fixture.events, conservativeReset)
        fixture.assertCompleted()
    }

    func testConfirmedHealthyResetPreservesFreshKeyboardSnapshot() throws {
        let fixture = try fixture()
        fixture.terminalFactor = 1
        try fixture.restore()
        XCTAssertEqual(fixture.events, healthyReset)
        XCTAssertFalse(fixture.hadWriteFailure)
        fixture.assertCompleted()
    }

    func testUnusedSessionCompletesWithoutHardwareWrites() throws {
        let fixture = try fixture(pending: false)
        fixture.context = nil
        fixture.terminalFactor = nil
        try fixture.restore()
        XCTAssertTrue(fixture.events.isEmpty)
        XCTAssertFalse(fixture.hadWriteFailure)
        fixture.assertCompleted()
    }
}
