import XCTest
import CoreGraphics
@testable import Backlit

final class LiveFadeHardwareTests: XCTestCase {
    private final class Fixture {
        var context: FadeSafetyContext? = .init(lidClosed: false, sleeping: false, locked: false, generation: 1)
        var ids: [UInt64]? = [13, 42]
        var states: [UInt64: NSNumber] = [13: 2, 42: 4]
        var events: [String] = []
        var rejected: String?
        var onWrite: ((String) -> Void)?
        var factor: Double? = 0
        var enabled: Bool? = false
        var now: Double = 0
        var waits: [Double] = []
        var onWait: (() -> Void)?
        var onFactorRead: (() -> Void)?
        func write(_ event: String) -> Bool {
            events.append(event); onWrite?(event); return rejected != event
        }
        func adapter() -> LiveFadeHardware {
            .init(interface: .init(context: { self.context }, keyboardIDs: { self.ids },
                keyboardState: { self.states[$0] },
                duration: { self.write("duration:\($0)") },
                logicalState: { self.write("global:\($0)") },
                keyboardLogicalState: { self.write("key:\($0):\($1)") },
                keyboardClosed: { self.write("closed:\($0)") },
                factor: { self.onFactorRead?(); return self.factor },
                logoEnabled: { self.enabled }, now: { self.now }, wait: { interval in
                    self.waits.append(interval); self.now += interval; self.onWait?()
                }))
        }
        func record(pending: Bool = true) -> FadeRecoveryRecord {
            let context = FadeSafetyContext(lidClosed: false, sleeping: false, locked: false, generation: 1)
            return .init(token: UUID(), parentPID: 123, originalContext: context,
                         keyboardStates: [13: 2, 42: 2], watchdogPID: 456,
                         effectsAllowed: false,
                         pendingBatch: pending ? .init(context: context, keyboardStates: [13: 2, 42: 2]) : nil)
        }
    }

    func testKeyboardSnapshotAcceptsEveryValidLogicalStateWithoutWrites() {
        let f = Fixture(), a = f.adapter()
        for state in 0...6 {
            f.states[13] = NSNumber(value: state)
            XCTAssertEqual(a.keyboardStates(), [13: state, 42: 4])
        }
        XCTAssertTrue(f.events.isEmpty)
    }

    func testMissingInvalidAndDuplicateKeyboardStateFailsClosed() {
        let f = Fixture(), a = f.adapter()
        for number in [NSNumber(value: -1), NSNumber(value: 7), NSNumber(value: 1.5),
                       NSNumber(value: Double.nan), NSNumber(value: Double.infinity), NSNumber(value: true)] {
            f.states[13] = number
            XCTAssertNil(a.keyboardStates())
        }
        f.states[13] = nil; XCTAssertNil(a.keyboardStates())
        f.states[13] = 2; f.ids = [13, 13]; XCTAssertNil(a.keyboardStates())
        f.ids = []; XCTAssertNil(a.keyboardStates())
        f.ids = nil; XCTAssertNil(a.keyboardStates())
        XCTAssertTrue(f.events.isEmpty)
    }

    func testGuardUsesFreshPerKeyboardStatesAndRestoresAfterPartialFailure() {
        let f = Fixture(), a = f.adapter()
        XCTAssertThrowsError(try a.guardedFadeWrite {
            f.events.append("body")
            throw NSError(domain: "fixture", code: 1)
        })
        XCTAssertEqual(f.events, ["body", "key:13:2", "key:42:4"])
    }

    func testGuardClosedKeyboardAlwaysUsesTrueClamshellNotification() throws {
        let f = Fixture(), a = f.adapter()
        f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 1)
        try a.guardedFadeWrite { f.events.append("body") }
        XCTAssertEqual(f.events, ["body", "closed:13", "closed:42"])
    }

    func testUnusedRecoveryRecordDoesNotReadOrWriteHardware() throws {
        let f = Fixture(), a = f.adapter()
        f.context = nil; f.ids = nil
        try a.restore(f.record(pending: false))
        XCTAssertTrue(f.events.isEmpty)
    }

    func testRecoveryUsesFreshStatesNotOriginalOrPendingUnblank() throws {
        let f = Fixture(), a = f.adapter()
        f.states = [13: 1, 42: 5]
        try a.restore(f.record())
        XCTAssertEqual(f.events, ["duration:5.0", "global:1", "duration:0.0", "global:2", "key:13:1", "key:42:5"])
    }

    func testRecoveryDoesNotReplayEvenFreshUnblankOfUnknownProvenance() throws {
        let f = Fixture(), a = f.adapter()
        try a.restore(f.record())
        XCTAssertTrue(f.events.contains("key:13:1"))
        XCTAssertFalse(f.events.contains("key:13:2"))
    }

    func testRecoveryDoesNotGloballyUnblankClosedSleepingOrLockedMac() throws {
        for context in [FadeSafetyContext(lidClosed: true, sleeping: false, locked: false, generation: 1),
                        .init(lidClosed: false, sleeping: true, locked: false, generation: 1),
                        .init(lidClosed: false, sleeping: false, locked: true, generation: 1)] {
            let f = Fixture(), a = f.adapter(); f.context = context
            try a.restore(f.record())
            XCTAssertFalse(f.events.contains("global:2"))
            XCTAssertEqual(Array(f.events.prefix(2)), ["duration:0.0", "global:1"])
            XCTAssertEqual(Array(f.events.suffix(2)), context.lidClosed ? ["closed:13", "closed:42"] : ["key:13:1", "key:42:1"])
        }
    }

    func testRecoveryCloseBetweenGlobalWritesStopsUnblankAndRestoresClosed() {
        let f = Fixture(), a = f.adapter()
        f.onWrite = { event in
            if event == "global:1" { f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 2) }
        }
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertFalse(f.events.contains("global:2"))
        XCTAssertEqual(Array(f.events.suffix(2)), ["closed:13", "closed:42"])
    }

    func testRecoveryCloseWhileRestoringKeyboardRechecksNextDevice() {
        let f = Fixture(), a = f.adapter()
        f.onWrite = { event in
            if event == "key:13:1" { f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 2) }
        }
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertEqual(f.events.last, "closed:42")
    }

    func testRecoveryRejectedGlobalWriteStillAttemptsAllKeyboards() {
        let f = Fixture(), a = f.adapter(); f.rejected = "global:1"
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertEqual(Array(f.events.suffix(2)), ["key:13:1", "key:42:4"])
    }

    func testRecoveryUnknownContextMakesNoWrites() {
        let f = Fixture(), a = f.adapter(); f.context = nil
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertTrue(f.events.isEmpty)
    }

    func testRecoveryWaitsForObservedTerminalOutputAfterAcceptedSetters() throws {
        let f = Fixture(), a = f.adapter(); f.factor = 0.4
        f.onWait = { if f.now >= 0.2 { f.factor = 1 } }
        try a.restore(f.record())
        XCTAssertGreaterThanOrEqual(f.now, 0.25)
        XCTAssertLessThan(f.now, 6)
        XCTAssertTrue(f.events.contains("global:2"))
    }

    func testNonterminalOutputTimesOutWithoutExtendingDeadline() {
        let f = Fixture(), a = f.adapter(); f.factor = 0.4
        f.onWait = { f.factor = f.factor == 0.4 ? 0.5 : 0.4 }
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertEqual(f.now, 6, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(f.waits.count, 122)
        XCTAssertTrue(f.events.contains("global:2"), "Accepted setters alone are insufficient")
    }

    func testTerminalTimeoutRetainsRevokedJournalUntilObservedRecovery() throws {
        let f = Fixture(), a = f.adapter(); f.factor = 0.4
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FadeRecoveryStore(directory: directory)
        let context = try XCTUnwrap(f.context)
        let token = try store.prepare(parentPID: 123, context: context, keyboards: [13: 2, 42: 4])
        try store.acknowledgeWatchdog(token: token, watchdogPID: 456, parentAlive: { _ in true })
        _ = try store.withPermission(token: token, watchdogAlive: { _ in true },
                                     snapshot: .init(context: context, keyboardStates: [13: 2, 42: 4])) {}
        XCTAssertThrowsError(try store.recover(token: token) { try a.restore($0) })
        let retained = try store.read()
        XCTAssertEqual(retained.token, token)
        XCTAssertFalse(retained.effectsAllowed)
        XCTAssertNotNil(retained.pendingBatch)
        f.factor = 0
        try store.recover(token: token) { try a.restore($0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testRecoveryDeadlineIncludesSetterTimeInsteadOfStartingAfterWrites() {
        let f = Fixture(), a = f.adapter(); f.factor = 0.4
        f.onWrite = { _ in f.now += 0.5 }
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertEqual(f.now, 6, accuracy: 0.000001)
        XCTAssertLessThan(f.waits.count, 65)
    }

    func testMissingAndInvalidFactorNeverConfirmsRecovery() {
        for factor: Double? in [nil, -0.1, 1.1, .nan, .infinity] {
            let f = Fixture(), a = f.adapter(); f.factor = factor
            XCTAssertThrowsError(try a.restore(f.record()))
            XCTAssertTrue(f.waits.isEmpty)
            XCTAssertEqual(Array(f.events.suffix(2)), ["key:13:1", "key:42:4"])
        }
    }

    func testClosedRecoveryRequiresZeroAndObservedDisabledPWM() throws {
        let f = Fixture(), a = f.adapter()
        f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 1)
        f.factor = 0.4; f.enabled = true
        f.onWait = {
            if f.now >= 0.1 { f.factor = 0 }
            if f.now >= 0.25 { f.enabled = false }
        }
        try a.restore(f.record())
        XCTAssertGreaterThanOrEqual(f.now, 0.3)
        XCTAssertFalse(f.events.contains("global:2"))
        XCTAssertEqual(Array(f.events.suffix(2)), ["closed:13", "closed:42"])
    }

    func testUnsafeRecoveryNeverAcceptsFullFactorEvenWhenPWMIsDisabled() {
        let f = Fixture(), a = f.adapter()
        f.context = .init(lidClosed: false, sleeping: false, locked: true, generation: 1)
        f.factor = 1; f.enabled = false
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertEqual(f.now, 6, accuracy: 0.000001)
    }

    func testClosedMissingEnableTelemetryRetainsRecovery() {
        let f = Fixture(), a = f.adapter()
        f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 1)
        f.factor = 0; f.enabled = nil
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertTrue(f.waits.isEmpty)
    }

    func testContextChangeWhileSettlingInvalidatesTerminalOutput() {
        let f = Fixture(), a = f.adapter(); f.factor = 0.4
        f.onWait = {
            f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 2)
            f.factor = 0
        }
        XCTAssertThrowsError(try a.restore(f.record()))
        XCTAssertEqual(f.waits.count, 1)
    }

    func testContextChangeDuringFactorReadCannotConfirmEndpoint() {
        let f = Fixture(), a = f.adapter()
        f.onFactorRead = { f.context = .init(lidClosed: false, sleeping: false, locked: true, generation: 2) }
        XCTAssertThrowsError(try a.confirmTerminal())
        XCTAssertTrue(f.events.isEmpty)
    }

    func testHealthyOpenConfirmationAllowsNativeGatedZeroOrFullEndpoint() throws {
        for factor in [0.0, 1.0] {
            let f = Fixture(), a = f.adapter(); f.factor = factor; f.enabled = nil
            try a.confirmTerminal()
            XCTAssertEqual(f.waits, [0.05])
            XCTAssertTrue(f.events.isEmpty, "Confirmation is read-only")
        }
    }

    func testSingleTransientEndpointDoesNotProveSettling() {
        let f = Fixture(), a = f.adapter(); f.factor = 0
        f.onWait = { f.factor = 0.5 }
        XCTAssertThrowsError(try a.confirmTerminal())
        XCTAssertEqual(f.now, 6, accuracy: 0.000001)
    }

    func testUnknownContextAndInvalidClockCannotConfirmEndpoint() {
        let f = Fixture(), a = f.adapter(); f.context = nil
        XCTAssertThrowsError(try a.confirmTerminal())
        for now in [Double.nan, .infinity, -1] {
            f.now = now
            XCTAssertThrowsError(try a.confirmTerminal())
        }
        XCTAssertTrue(f.events.isEmpty)
    }

    func testRegressingClockCannotExtendRecoveryAttempt() {
        let f = Fixture(), a = f.adapter(); f.factor = 0.4
        f.onWait = { f.now = 0 }
        XCTAssertThrowsError(try a.confirmTerminal())
        XCTAssertEqual(f.waits.count, 1)
    }

    func testEveryObservedTransitionInvalidatesGenerationEvenAwayAndBack() throws {
        let observer = FadeSafetyObservation()
        let state = FadeSafetyObservation.State(lidClosed: false, sleeping: false, locked: false)
        let before = try XCTUnwrap(observer.context { state })
        observer.observe(.changed); observer.observe(.changed)
        let after = try XCTUnwrap(observer.context { state })
        XCTAssertGreaterThan(after.generation, before.generation)
        XCTAssertEqual(after.lidClosed, before.lidClosed)
        XCTAssertEqual(after.sleeping, before.sleeping)
        XCTAssertEqual(after.locked, before.locked)
    }

    func testSleepSessionAndLockNotificationsInhibitUntilTheirMatchingReturn() throws {
        for (away, back): (FadeSafetyObservation.Event, FadeSafetyObservation.Event) in [
            (.willSleep, .didWake), (.resignedSession, .activeSession), (.locked, .unlocked)
        ] {
            let observer = FadeSafetyObservation()
            let state = FadeSafetyObservation.State(lidClosed: false, sleeping: false, locked: false)
            let initial = try XCTUnwrap(observer.context { state })
            observer.observe(away)
            XCTAssertFalse(try XCTUnwrap(observer.context { state }).permitsOpenKeyboardRestore)
            observer.observe(back)
            let after = try XCTUnwrap(observer.context { state })
            XCTAssertTrue(after.permitsOpenKeyboardRestore)
            XCTAssertGreaterThan(after.generation, initial.generation)
        }
    }

    func testUnknownAndChangedDuringReadNeverProducePermissiveContext() throws {
        let observer = FadeSafetyObservation()
        let state = FadeSafetyObservation.State(lidClosed: false, sleeping: false, locked: false)
        let before = try XCTUnwrap(observer.context { state })
        XCTAssertNil(observer.context { nil })
        XCTAssertNil(observer.context { observer.observe(.changed); return state })
        XCTAssertGreaterThan(try XCTUnwrap(observer.context { state }).generation, before.generation)
    }

    func testSleepCycleChangesInvalidateButPresenceDoesNotMeanSleeping() throws {
        let observer = FadeSafetyObservation()
        var state = FadeSafetyObservation.State(lidClosed: false, sleeping: false, locked: false, sleepCycle: "one")
        let before = try XCTUnwrap(observer.context { state })
        XCTAssertFalse(before.sleeping)
        state.sleepCycle = "two"
        let after = try XCTUnwrap(observer.context { state })
        XCTAssertFalse(after.sleeping)
        XCTAssertGreaterThan(after.generation, before.generation)
    }

    private final class SnapshotFixture {
        var lid: Any? = false
        var cycle: Any?
        var session: Any? = ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true]
        var displays: [UInt32] = [11, 22]
        var count: UInt32 = 2
        var result: CGError = .success
        var sleeping: Set<UInt32> = []
        var checkedDisplays: [UInt32] = []
        func parse() -> FadeSafetyObservation.State? {
            FadeSafetySnapshot.parse(lid: lid, sleepCycle: cycle, session: session,
                displays: displays, displayCount: count, displayResult: result, isAsleep: { id in
                    self.checkedDisplays.append(id); return self.sleeping.contains(id)
                })
        }
    }

    func testSnapshotParserAllowsValidatedUnlockedSessionWithoutOptionalKeys() throws {
        let f = SnapshotFixture()
        XCTAssertEqual(try XCTUnwrap(f.parse()), .init(lidClosed: false, sleeping: false, locked: false))
        f.cycle = "cycle-one"
        let state = try XCTUnwrap(f.parse())
        XCTAssertEqual(state.sleepCycle, "cycle-one")
        XCTAssertFalse(state.sleeping, "UUID presence alone never means asleep")
    }

    func testSnapshotParserRejectsUnknownOrMalformedRequiredFields() {
        let invalid: [Any?] = [nil, "false", [String: Bool]()]
        for value in invalid {
            let f = SnapshotFixture(); f.lid = value
            XCTAssertNil(f.parse()); XCTAssertTrue(f.checkedDisplays.isEmpty)
        }
        for value: Any? in [nil, "session", [String: Bool](),
                           ["kCGSSessionOnConsoleKey": true], ["kCGSessionLoginDoneKey": true],
                           ["kCGSSessionOnConsoleKey": "yes", "kCGSessionLoginDoneKey": true]] {
            let f = SnapshotFixture(); f.session = value
            XCTAssertNil(f.parse()); XCTAssertTrue(f.checkedDisplays.isEmpty)
        }
    }

    func testSnapshotParserRejectsMalformedOptionalFields() {
        let f = SnapshotFixture(); f.cycle = 123
        XCTAssertNil(f.parse()); XCTAssertTrue(f.checkedDisplays.isEmpty)
        f.cycle = nil
        f.session = ["kCGSSessionOnConsoleKey": true, "kCGSessionLoginDoneKey": true, "CGSSessionScreenIsLocked": "no"]
        XCTAssertNil(f.parse()); XCTAssertTrue(f.checkedDisplays.isEmpty)
    }

    func testSnapshotParserPreservesExplicitLockInactiveAndIncompleteLogin() throws {
        for (onConsole, loginDone, locked) in [(true, true, true), (false, true, false), (true, false, false)] {
            let f = SnapshotFixture()
            f.session = ["kCGSSessionOnConsoleKey": onConsole, "kCGSessionLoginDoneKey": loginDone,
                         "CGSSessionScreenIsLocked": locked]
            XCTAssertTrue(try XCTUnwrap(f.parse()).locked)
        }
    }

    func testSnapshotParserRejectsDisplayErrorEmptyOverflowAndShortBuffer() {
        let f = SnapshotFixture(); f.result = .failure
        XCTAssertNil(f.parse()); XCTAssertTrue(f.checkedDisplays.isEmpty)
        f.result = .success
        for count: UInt32 in [0, 3, 65, .max] {
            f.count = count
            XCTAssertNil(f.parse()); XCTAssertTrue(f.checkedDisplays.isEmpty)
        }
    }

    func testSnapshotParserAcceptsCapacityBoundaryAndIgnoresUnusedTail() throws {
        let f = SnapshotFixture()
        f.displays = Array(1...64); f.count = 64; f.sleeping = Set(f.displays)
        XCTAssertTrue(try XCTUnwrap(f.parse()).sleeping)
        XCTAssertEqual(f.checkedDisplays, f.displays)
        f.displays = [11] + Array(repeating: 0, count: 63)
        f.count = 1; f.sleeping = [11]; f.checkedDisplays = []
        XCTAssertTrue(try XCTUnwrap(f.parse()).sleeping)
        XCTAssertEqual(f.checkedDisplays, [11])
    }

    func testSnapshotParserUsesFreshDisplayStatusAndLidOnEveryCall() throws {
        let f = SnapshotFixture(); f.sleeping = [11, 22]
        let observer = FadeSafetyObservation()
        let before = try XCTUnwrap(observer.context { f.parse() })
        XCTAssertTrue(before.sleeping)
        f.lid = true; f.sleeping = [11]; f.checkedDisplays = []
        let after = try XCTUnwrap(observer.context { f.parse() })
        XCTAssertFalse(after.sleeping); XCTAssertTrue(after.lidClosed)
        XCTAssertGreaterThan(after.generation, before.generation)
        XCTAssertEqual(f.checkedDisplays, [11, 22])
    }

    func testSnapshotParserStillInvalidatesReadInterruptedByObservedEvent() {
        let f = SnapshotFixture(), observer = FadeSafetyObservation()
        XCTAssertNil(observer.context {
            let state = f.parse()
            observer.observe(.changed)
            return state
        })
    }
}
