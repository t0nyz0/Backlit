import XCTest
@testable import Backlit

final class FadeFrameOutcomeTests: XCTestCase {
    /// The actual runtime permission/planner/write path with inert hardware,
    /// a temporary journal and no native client or watchdog process.
    final class Fixture: FadeEffectSession {
        let directory: URL
        let store: FadeRecoveryStore
        let token: UUID
        var context: FadeSafetyContext? = .init(lidClosed: false, sleeping: false, locked: false, generation: 1)
        var sample: ClosedLidEffect.Sample? = .init(factor: 0, appliedNits: 0, multiplier: 1)
        var now = 0.0
        var events: [String] = []
        var permission = true
        var hadWriteFailure = false
        var rejected: String?
        var onLogicalState: ((Int) -> Bool)?
        lazy var hardware = LiveFadeHardware(interface: .init(
            context: { self.context }, keyboardIDs: { [7] }, keyboardState: { _ in NSNumber(value: 2) },
            duration: { self.write("recovery:duration:\($0)") }, logicalState: { self.write("recovery:state:\($0)") },
            keyboardLogicalState: { self.write("keyboard:\($0):\($1)") }, keyboardClosed: { self.write("closed:\($0)") },
            factor: { self.sample?.factor }, logoEnabled: { false }, now: { self.now }, wait: { self.now += $0 }))
        lazy var effect = ClosedLidEffect(interface: .init(sample: { self.sample },
            duration: { self.write("duration:\($0)") }, logicalState: {
                self.write("state:\($0)") && (self.onLogicalState?($0) ?? true)
            },
            keepKeyboardDark: { true }, now: { self.now }))
        var needsAnimation: Bool { effect.needsAnimation }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = FadeRecoveryStore(directory: directory)
            token = try store.prepare(parentPID: 123, context: context!, keyboards: [7: 2])
            try store.acknowledgeWatchdog(token: token, watchdogPID: 456, parentAlive: { _ in true })
        }
        func write(_ event: String) -> Bool { events.append(event); return event != rejected }
        func apply(_ brightness: Double, closedLidRequested: Bool = false, frameInterval: Double = 0.05) throws -> FadeApplyResult {
            try FadeRuntime.applyPermittedFrame(brightness, closedLidRequested: closedLidRequested,
                frameInterval: frameInterval, effect: effect, hardware: hardware, store: store, token: token,
                watchdogPID: 456, watchdogAlive: { true }, lidPermission: { self.permission },
                markWriteFailure: { self.hadWriteFailure = true })
        }
        func restore() throws {
            try store.recover(token: token) { record in
                try FadeRuntime.restore(record, hardware: hardware, effect: effect, hadWriteFailure: hadWriteFailure) {
                    self.hadWriteFailure = true
                }
            }
            effect.relinquish()
        }
    }
    private func fixture() throws -> Fixture {
        let value = try Fixture()
        addTeardownBlock { try FileManager.default.removeItem(at: value.directory) }
        return value
    }

    func testGatedPositiveSourceWaitsWithoutWriteBatchAndRetainsDeadline() throws {
        for source in [(0.0, 1.0), (100.0, 0.0), (0.0, 0.0)] {
            let f = try fixture()
            f.sample = .init(factor: 0, appliedNits: source.0, multiplier: source.1)
            XCTAssertEqual(try f.apply(0.7), .waiting)
            XCTAssertTrue(f.events.isEmpty)
            XCTAssertNil(try f.store.read().pendingBatch)
            XCTAssertTrue(f.needsAnimation, "The existing deadline must continue to be polled")
            f.now = 2.99
            XCTAssertEqual(try f.apply(0.7), .waiting)
            f.now = 3
            XCTAssertThrowsError(try f.apply(0.7)) { XCTAssertTrue($0 is FadeSessionInterruption) }
            XCTAssertTrue(f.events.isEmpty)
        }
    }

    func testNeverWrittenSourceWaitCanStopPollingWithoutHardwareCleanup() throws {
        let f = try fixture()
        XCTAssertEqual(try f.apply(0.7), .waiting)
        XCTAssertTrue(f.needsAnimation)
        try f.effect.restore()
        XCTAssertFalse(f.needsAnimation)
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertNil(try f.store.read().pendingBatch)
    }

    func testFirstPositiveRiseAndNoWriteZeroRiseWaitUntilObservedOutput() throws {
        let f = try fixture()
        f.sample = .init(factor: 0, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try f.apply(0.7), .waiting)
        XCTAssertFalse(f.events.isEmpty)
        XCTAssertNotNil(try f.store.read().pendingBatch)
        let count = f.events.count
        f.now = 1
        XCTAssertEqual(try f.apply(0.8), .waiting)
        XCTAssertEqual(f.events.count, count, "A gated rise must not be repeatedly restarted")
        f.sample = .init(factor: 0.2, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try f.apply(0.8), .applied, "Moving interior output need not equal its changing target")
    }

    func testFreshOwnerPrimesStaleNativeUnblankAndWaitsForObservedRise() throws {
        for closed in [false, true] {
            for target in [0.7, 1.0] {
                let f = try fixture()
                f.context = .init(lidClosed: closed, sleeping: false, locked: false, generation: 1)
                try f.store.setClosedLidRequested(token: f.token, value: closed)
                f.sample = .init(factor: 0, appliedNits: 279, multiplier: 1)
                var nativeState = 2
                var transitions: [Int] = []
                // Minimal native model: accepting the already selected state
                // does not reevaluate it or start a rise. A changed state may
                // arm output, but observation remains independent of success.
                f.onLogicalState = { state in
                    guard state != nativeState else { return true }
                    XCTAssertNotNil(try? f.store.read().pendingBatch)
                    nativeState = state
                    transitions.append(state)
                    return true
                }
                XCTAssertTrue(f.onLogicalState!(2))
                XCTAssertTrue(transitions.isEmpty)
                XCTAssertEqual(f.sample?.factor, 0)

                if closed {
                    f.permission = false
                    XCTAssertEqual(try f.apply(target, closedLidRequested: true), .waiting)
                    XCTAssertTrue(f.events.isEmpty)
                    XCTAssertNil(try f.store.read().pendingBatch)
                    f.permission = true
                }
                XCTAssertEqual(try f.apply(target, closedLidRequested: closed), .waiting)
                XCTAssertEqual(transitions, [1, 2], "A fresh owner must prime stale native Unblank")
                XCTAssertEqual(f.events.last, closed ? "closed:7" : "keyboard:7:2")
                XCTAssertEqual(try f.store.read().pendingBatch?.keyboardStates, [7: 2])
                XCTAssertEqual(f.sample?.factor, 0, "Setter acceptance is not observed output")
                let count = f.events.count
                for tick in 1...20 {
                    f.now = Double(tick) * 0.05
                    let pendingTarget = target == 1 ? target : target + Double(tick) * 0.005
                    XCTAssertEqual(try f.apply(pendingTarget, closedLidRequested: closed), .waiting)
                    XCTAssertTrue(f.needsAnimation)
                }
                XCTAssertEqual(f.events.count, count, "Waiting must not repeatedly rearm the native fade")
                XCTAssertEqual(transitions, [1, 2])
                // Only the primed transition permits the simulated later rise.
                if transitions == [1, 2] {
                    f.sample = .init(factor: target == 1 ? 1 : 0.2, appliedNits: 279, multiplier: 1)
                }
                XCTAssertEqual(try f.apply(target, closedLidRequested: closed), .applied)
                XCTAssertFalse(f.hadWriteFailure)
            }
        }
    }

    func testEndpointsWaitForSubsequentExactObservationThenSettleWithoutWrites() throws {
        for target in [0.0, 1.0] {
            let f = try fixture()
            f.sample = .init(factor: target == 0 ? 1 : 0, appliedNits: 100, multiplier: 1)
            XCTAssertEqual(try f.apply(target), .waiting)
            let count = f.events.count
            f.now = 1
            XCTAssertEqual(try f.apply(target), .waiting)
            XCTAssertEqual(f.events.count, count)
            f.sample = .init(factor: target, appliedNits: 100, multiplier: 1)
            f.now = 10
            XCTAssertEqual(try f.apply(target), .applied, "Observed endpoint beats the elapsed deadline")
            XCTAssertEqual(try f.apply(target), .applied)
            XCTAssertEqual(f.events.count, count)
            XCTAssertFalse(f.needsAnimation)
        }
    }

    func testInitialOffAtZeroSourceRequiresCommandAndLaterObservation() throws {
        let f = try fixture()
        XCTAssertEqual(try f.apply(0), .waiting)
        XCTAssertEqual(f.events.filter { $0.hasPrefix("state:") }, ["state:2", "state:1"])
        let count = f.events.count
        XCTAssertEqual(try f.apply(0), .applied)
        XCTAssertEqual(f.events.count, count)
    }

    func testInteriorHoldCanBeAppliedWithoutAnotherWrite() throws {
        let f = try fixture()
        f.sample = .init(factor: 0.5, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try f.apply(0.5), .applied)
        let count = f.events.count
        XCTAssertEqual(try f.apply(0.5), .applied)
        XCTAssertEqual(f.events.count, count)
    }

    func testSourceReturnStillWaitsForFirstRiseThenRecoversWithoutNewRetries() throws {
        let f = try fixture()
        XCTAssertEqual(try f.apply(0.5), .waiting)
        f.now = 1
        f.sample = .init(factor: 0, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try f.apply(0.5), .waiting)
        f.now = 2
        f.sample = .init(factor: 0.5, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try f.apply(0.5), .applied)
        f.sample = .init(factor: 0.5, appliedNits: 0, multiplier: 1)
        XCTAssertEqual(try f.apply(0.5), .waiting, "Even exact factor does not bypass a missing positive source")
        f.now = 5
        XCTAssertThrowsError(try f.apply(0.5)) { XCTAssertTrue($0 is FadeSessionInterruption) }
    }

    func testPendingEndpointSourceReturnClearsWaitingDeadline() throws {
        let f = try fixture()
        f.sample = .init(factor: 0.5, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try f.apply(1), .waiting)
        f.sample = .init(factor: 1, appliedNits: 0, multiplier: 1)
        f.now = 1
        XCTAssertEqual(try f.apply(1), .waiting)
        f.sample = .init(factor: 1, appliedNits: 100, multiplier: 1)
        f.now = 10
        XCTAssertEqual(try f.apply(1), .applied)
        XCTAssertFalse(f.needsAnimation)
    }

    func testInvalidSampleAndFailedWritesCannotBecomeApplied() throws {
        let f = try fixture()
        f.sample = nil
        XCTAssertThrowsError(try f.apply(0.5))
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertNil(try f.store.read().pendingBatch)
        f.sample = .init(factor: 0.5, appliedNits: 100, multiplier: 1)
        f.rejected = "state:2"
        XCTAssertThrowsError(try f.apply(0.5))
        XCTAssertTrue(f.hadWriteFailure)
        XCTAssertNotNil(try f.store.read().pendingBatch)
    }

    func testFreshSafetyAndPermissionGatesStillPreventPlanningWrites() throws {
        for context in [FadeSafetyContext(lidClosed: false, sleeping: true, locked: false, generation: 1),
                        .init(lidClosed: false, sleeping: false, locked: true, generation: 1),
                        .init(lidClosed: true, sleeping: false, locked: false, generation: 1)] {
            let f = try fixture()
            f.context = context; f.permission = false
            XCTAssertEqual(try f.apply(0.7, closedLidRequested: true), .waiting)
            XCTAssertTrue(f.events.isEmpty)
            XCTAssertNil(try f.store.read().pendingBatch)
        }
    }

    func testZeroRiseAndEndpointDeadlinesRemainFailuresThroughRuntime() throws {
        for target in [0.7, 1.0] {
            let f = try fixture()
            f.sample = .init(factor: 0, appliedNits: 100, multiplier: 1)
            XCTAssertEqual(try f.apply(target), .waiting)
            let count = f.events.count
            f.now = 3
            XCTAssertThrowsError(try f.apply(target)) { XCTAssertTrue($0 is FadeSessionInterruption) }
            XCTAssertEqual(f.events.count, count)
        }
    }

    func testWaitingReplacementDoesNotClaimAutomaticRecoverySucceeded() throws {
        let first = try fixture(), replacement = try fixture()
        var time = 0.0, made = 0
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { time }, makeSession: { _ in
            made += 1
            return made == 1 ? first : replacement
        })
        XCTAssertEqual(try owner.apply(0.5, closedLidRequested: false, frameInterval: 0.05), .waiting)
        time = 3; first.now = time
        XCTAssertEqual(try owner.apply(0.5, closedLidRequested: false, frameInterval: 0.05), .waiting)
        XCTAssertTrue(owner.automaticRecoveryPending)
        time = 4; replacement.now = time
        XCTAssertEqual(try owner.apply(0.5, closedLidRequested: false, frameInterval: 0.05), .waiting)
        XCTAssertEqual(made, 2)
        XCTAssertTrue(owner.automaticRecoveryPending, "A no-write source wait cannot count as recovery success")
        replacement.sample = .init(factor: 0.5, appliedNits: 100, multiplier: 1)
        XCTAssertEqual(try owner.apply(0.5, closedLidRequested: false, frameInterval: 0.05), .applied)
        XCTAssertFalse(owner.automaticRecoveryPending)
    }

    @MainActor func testRuntimeWaitingFlowsThroughCoordinatorAndInvalidatesReadyBanner() throws {
        let f = try fixture()
        let owner = FadeSessionCoordinator(physicalLid: { false }, now: { f.now }, makeSession: { _ in f })
        let suite = "Backlit.FrameOutcome." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults, hardwareRestore: {}, hardwareApply: { level, closed in
            try owner.apply(level, closedLidRequested: closed, frameInterval: 0.05)
        })
        model.mode = .steady; model.brightness = 0.5; model.controlWanted = true
        defer { model.controlling = false }
        model.tick(); model.announceLightReadiness()
        XCTAssertFalse(model.lightReady); XCTAssertNil(model.notice)
        f.sample = .init(factor: 0, appliedNits: 100, multiplier: 1)
        model.tick(); model.announceLightReadiness()
        XCTAssertFalse(model.lightReady); XCTAssertNil(model.notice)
        f.sample = .init(factor: 0.5, appliedNits: 100, multiplier: 1)
        model.tick(); model.announceLightReadiness()
        XCTAssertTrue(model.lightReady); XCTAssertEqual(model.notice, "Your light is ready.")
        f.sample = .init(factor: 0.5, appliedNits: 0, multiplier: 1)
        model.tick()
        XCTAssertFalse(model.lightReady); XCTAssertNil(model.notice)
    }
}
