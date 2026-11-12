import XCTest
@testable import Backlit

final class IndependentLogoSourceTests: XCTestCase {
    final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original: [[Double]] = [[0, 0], [300, 300], [Double(Float.greatestFiniteMagnitude), 1000]]
        let store: FadeRecoveryStore
        let source: IndependentLogoSource
        let token: UUID
        var context = FadeSafetyContext(lidClosed: false, sleeping: false, locked: false, generation: 1)
        var mapping: [[Double]]
        var factor = 1.0
        var nits = 150.0
        var clock = 0.0
        var events: [String] = []
        var failMapping = false
        var failRefresh = false
        var invalidateOnMapping = false
        var refreshChangesMapping = false
        var waitForRefresh = false
        var writeFailed = false
        lazy var hardware = LiveFadeHardware(interface: .init(
            context: { self.context }, keyboardIDs: { [7] }, keyboardState: { _ in 2 },
            duration: { self.events.append("duration:\($0)"); return true },
            logicalState: { self.events.append("state:\($0)"); self.factor = $0 == 2 ? 1 : 0; return true },
            keyboardLogicalState: { _, _ in self.events.append("keyboard"); return true }, keyboardClosed: { _ in self.events.append("closed-keyboard"); return true },
            factor: { self.factor }, logoEnabled: { self.factor > 0 && self.nits > 0 },
            mapping: { self.mapping }, setMapping: { value in
                self.events.append("mapping")
                let record = try? self.store.read()
                XCTAssertNotNil(record?.pendingBatch, "Mapping cannot precede durable write permission")
                XCTAssertTrue(record?.logoSource?.owns(value) == true)
                self.mapping = value
                if !self.waitForRefresh { self.nits = value[0][1] }
                if self.invalidateOnMapping { self.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 2) }
                return !self.failMapping
            }, refreshMapping: {
                self.events.append("refresh")
                self.nits = self.mapping[0][1]
                self.factor = 1 // Worst case: native refresh resets the fade.
                if self.refreshChangesMapping { self.mapping = [[0, 42], [1000, 42]] }
                return !self.failRefresh
            }, now: { self.clock }, wait: { self.clock += $0 }))
        lazy var effect = ClosedLidEffect(interface: .init(sample: { .init(factor: self.factor, appliedNits: self.nits, multiplier: 1) },
            duration: { self.events.append("effect-duration:\($0)"); return true },
            logicalState: { self.events.append("effect-state:\($0)"); self.factor = $0 == 2 ? 1 : 0; return true }, keepKeyboardDark: { true }, now: { self.clock }))
        init() throws {
            mapping = original
            source = IndependentLogoSource(original: original)
            store = FadeRecoveryStore(directory: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            token = try store.prepare(parentPID: 123, context: context, keyboards: [7: 2], logoSource: source.recovery)
            try store.acknowledgeWatchdog(token: token, watchdogPID: 456, parentAlive: { _ in true })
        }
        func apply(_ level: Double) throws -> FadeApplyResult {
            try FadeRuntime.applyPermittedFrame(level, closedLidRequested: false, frameInterval: 0.05,
                effect: effect, hardware: hardware, store: store, token: token, watchdogPID: 456,
                watchdogAlive: { true }, lidPermission: { false }, source: source,
                markWriteFailure: { self.writeFailed = true })
        }
        func restore() throws {
            try store.recover(token: token) {
                try FadeRuntime.restore($0, hardware: self.hardware, effect: self.effect, hadWriteFailure: self.writeFailed) { self.writeFailed = true }
            }
        }
    }
    func fixture() throws -> Fixture {
        let f = try Fixture(); addTeardownBlock { try FileManager.default.removeItem(at: f.directory) }; return f
    }
    func testRequestedCurveDoesNotDependOnScreenBaseline() throws {
        for native in [0.0, 150, 500] {
            let f = try fixture(); f.nits = native
            _ = try f.apply(0.75)
            XCTAssertEqual(f.mapping, LogoSourceRecovery.curve(0.75))
            XCTAssertEqual(f.nits, 750)
        }
    }
    func testRefreshCanResetFactorWithoutExceedingRequestedSource() throws {
        for target in [0.0, 0.01, 0.5, 1] {
            let f = try fixture(); _ = try f.apply(target)
            XCTAssertEqual(f.mapping[0][1], target * 1000)
            XCTAssertLessThanOrEqual(f.mapping[0][1] * f.factor, target * 1000)
        }
    }
    func testChangedTargetUpdatesMappingWithoutRearmingRefresh() throws {
        let f = try fixture(); _ = try f.apply(0.5); f.events.removeAll()
        _ = try f.apply(0.8)
        XCTAssertEqual(f.mapping, LogoSourceRecovery.curve(0.8))
        XCTAssertFalse(f.events.contains("refresh"))
        let record = try f.store.read()
        XCTAssertEqual(record.logoSource?.previous, LogoSourceRecovery.curve(0.5))
        XCTAssertEqual(record.logoSource?.requested, LogoSourceRecovery.curve(0.8))
    }
    func testUnchangedTargetStillValidatesOwnership() throws {
        let f = try fixture(); _ = try f.apply(0.5); _ = try f.apply(0.5)
        f.mapping = [[0,42],[1000,42]]; f.events.removeAll()
        XCTAssertThrowsError(try f.apply(0.5)); XCTAssertTrue(f.events.isEmpty)
    }
    func testRejectedSetterThatMutatesRemainsRecoverable() throws {
        let f = try fixture(); f.failMapping = true
        XCTAssertThrowsError(try f.apply(0.5)); XCTAssertTrue(f.writeFailed)
        XCTAssertTrue(try f.store.read().logoSource!.owns(f.mapping))
        f.failMapping = false; try f.restore()
        XCTAssertEqual(f.mapping, f.original); XCTAssertTrue(f.store.completed(token: f.token))
    }
    func testSafetyChangeAfterMappingPreventsRefreshAndRestoresKeyboard() throws {
        let f = try fixture(); f.invalidateOnMapping = true
        XCTAssertThrowsError(try f.apply(0.5))
        XCTAssertFalse(f.events.contains("refresh")); XCTAssertTrue(f.events.contains("closed-keyboard"))
        XCTAssertNotNil(try f.store.read().pendingBatch)
    }
    func testRestoreFailureAfterOriginalWriteRetriesRefreshBeforeCompletion() throws {
        let f = try fixture(); _ = try f.apply(0.5); f.events.removeAll(); f.failRefresh = true
        XCTAssertThrowsError(try f.restore()); XCTAssertEqual(f.mapping, f.original)
        XCTAssertFalse(f.store.completed(token: f.token)); XCTAssertFalse(try f.store.read().effectsAllowed)
        f.failRefresh = false; f.events.removeAll(); try f.restore()
        XCTAssertTrue(f.events.contains("refresh")); XCTAssertTrue(f.store.completed(token: f.token))
    }
    func testRefreshChangingRestoredMappingCannotClearJournal() throws {
        let f = try fixture(); _ = try f.apply(0.5); f.refreshChangesMapping = true
        XCTAssertThrowsError(try f.restore()); XCTAssertFalse(f.store.completed(token: f.token))
    }
    func testOriginalMappingIsConfirmedBeforeUnblank() throws {
        let f = try fixture(); _ = try f.apply(0.5); f.events.removeAll(); try f.restore()
        XCTAssertLessThan(f.events.firstIndex(of: "mapping")!, f.events.firstIndex(of: "effect-state:2")!)
        XCTAssertEqual(f.mapping, f.original)
    }
    func testClosedRecoveryDoesNotRefreshOrUnblank() throws {
        let f = try fixture(); _ = try f.apply(0.5)
        f.context = .init(lidClosed: true, sleeping: false, locked: false, generation: 2)
        f.events.removeAll(); try f.restore()
        XCTAssertEqual(f.mapping, f.original)
        XCTAssertFalse(f.events.contains("refresh")); XCTAssertFalse(f.events.contains("state:2"))
    }
    func testUnacknowledgedWatchdogCannotWriteSource() throws {
        let f = try fixture(); try f.store.recover(token: f.token) { _ in }
        XCTAssertThrowsError(try f.apply(0.5)); XCTAssertTrue(f.events.isEmpty)
    }
    func testPositiveAfterZeroReappliesGatedNativeSource() throws {
        let f = try fixture(); _ = try f.apply(0.5); _ = try f.apply(0)
        f.waitForRefresh = true; f.events.removeAll()
        _ = try f.apply(0.7)
        XCTAssertEqual(f.mapping, LogoSourceRecovery.curve(0.7))
        XCTAssertEqual(f.nits, 700)
        XCTAssertTrue(f.events.contains("refresh"))
    }
    func testClosedOnlySessionCannotClaimIndependentMapping() {
        final class ClosedSession: FadeEffectSession {
            var needsAnimation = false
            func apply(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double) throws -> FadeApplyResult { .applied }
            func restore() throws {}
        }
        let coordinator = FadeSessionCoordinator(physicalLid: { true }, makeSession: { _ in ClosedSession() })
        XCTAssertNoThrow(try coordinator.apply(0.5, closedLidRequested: true, frameInterval: 0.05))
        XCTAssertTrue(coordinator.hasSession)
        XCTAssertFalse(coordinator.ownsIndependentSource)
    }
    func testOldJournalWithoutSourceStillDecodes() throws {
        let f = try fixture()
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.store.url)) as! [String: Any]
        object.removeValue(forKey: "logoSource")
        let record = try JSONDecoder().decode(FadeRecoveryRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(record.logoSource)
    }
}
