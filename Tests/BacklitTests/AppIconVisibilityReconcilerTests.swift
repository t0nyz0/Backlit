import XCTest
@testable import Backlit

@MainActor final class AppIconVisibilityReconcilerTests: XCTestCase {
    @MainActor private final class Fixture {
        var desired = AppIconVisibility(dock: false, menuBar: true)
        var actual = AppIconVisibility(dock: true, menuBar: false)
        var canChangePolicy = true
        var events: [String] = []
        var pending: [() -> Void] = []
        var applies = 0
        var failure: String?
        var onPolicyChange: (() -> Void)?
        lazy var controller = AppIconVisibilityController(dockIsVisible: { self.actual.dock },
            menuBarIsAvailable: { self.actual.menuBar }, setDockVisible: { visible in
                self.events.append(visible ? "dock:on" : "dock:off")
                guard self.canChangePolicy else { return false }
                self.actual.dock = visible
                self.onPolicyChange?()
                return true
            }, setMenuBarVisible: { visible in
                self.events.append(visible ? "menu:on" : "menu:off")
                self.actual.menuBar = visible
            })
        lazy var reconciler = AppIconVisibilityReconciler(requested: { self.desired },
            isApplied: { self.controller.isApplied($0) }, apply: {
                self.applies += 1
                let result = self.controller.apply(self.desired)
                self.desired = result.visibility
                self.failure = result.failure
            }, enqueue: { self.pending.append($0) })
        func drain() {
            var remaining = 5
            while !pending.isEmpty && remaining > 0 {
                remaining -= 1; pending.removeFirst()()
            }
            XCTAssertTrue(pending.isEmpty, "Reconciliation must not retry forever")
        }
    }
    func testStartupRechecksPolicyAfterAnInitiallySuccessfulHideAndLateLaunchDrift() {
        let fixture = Fixture()
        fixture.desired = fixture.controller.apply(fixture.desired).visibility
        XCTAssertFalse(fixture.actual.dock)
        fixture.reconciler.request()
        XCTAssertTrue(fixture.pending.isEmpty, "Do not reconcile before startup wiring is ready")
        fixture.reconciler.start()
        XCTAssertEqual(fixture.pending.count, 1)
        // Model startup may wait on Keychain; AppKit finishes activation later.
        fixture.actual.dock = true
        fixture.events.removeAll()
        fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
        XCTAssertEqual(fixture.events, ["menu:on", "dock:off"])
        XCTAssertEqual(fixture.actual, .init(dock: false, menuBar: true))
    }
    func testReopenAndActivationRequestsCoalesceAndAnAlreadyCorrectStateMakesNoNativeCalls() {
        let fixture = Fixture(); fixture.actual = fixture.desired
        fixture.reconciler.start()
        for _ in 0..<100 { fixture.reconciler.request() }
        XCTAssertEqual(fixture.pending.count, 1)
        fixture.drain()
        XCTAssertEqual(fixture.applies, 0)
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.actual.dock = true
        for _ in 0..<100 { fixture.reconciler.request() }
        XCTAssertEqual(fixture.pending.count, 1)
        fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
        XCTAssertEqual(fixture.events.filter { $0 == "dock:off" }.count, 1)
        for _ in 0..<100 { fixture.reconciler.request() }
        fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
    }
    func testSynchronousActivationFromPolicyChangeCannotScheduleAResyncLoop() {
        let fixture = Fixture()
        fixture.onPolicyChange = { fixture.reconciler.request() }
        fixture.reconciler.start()
        fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
        XCTAssertTrue(fixture.pending.isEmpty)
        fixture.reconciler.request(); fixture.drain()
        XCTAssertEqual(fixture.applies, 1, "A later native notification becomes a no-op once correct")
    }
    func testDeferredRecheckUsesCurrentPreferenceInsteadOfAnOldScheduledValue() {
        let fixture = Fixture(); fixture.actual = .init(dock: true, menuBar: true)
        fixture.reconciler.start()
        fixture.desired = .init(dock: true, menuBar: true)
        fixture.drain()
        XCTAssertEqual(fixture.applies, 0)
        XCTAssertTrue(fixture.events.isEmpty)
    }
    func testAnExplicitHiddenMenuChoiceIsRestoredWithoutTurningItOn() {
        let fixture = Fixture()
        fixture.desired = .init(dock: true, menuBar: false)
        fixture.actual = .init(dock: false, menuBar: true)
        fixture.reconciler.start(); fixture.drain()
        XCTAssertEqual(fixture.events, ["dock:on", "menu:off"])
        XCTAssertEqual(fixture.actual, .init(dock: true, menuBar: false))
        XCTAssertEqual(fixture.desired, fixture.actual)
    }
    func testFailedCorrectionPreservesAnEntryAndDoesNotAutomaticallyRetry() {
        let fixture = Fixture(); fixture.canChangePolicy = false
        fixture.actual = .init(dock: true, menuBar: true)
        fixture.reconciler.start(); fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
        XCTAssertNotNil(fixture.failure)
        XCTAssertEqual(fixture.actual, .init(dock: true, menuBar: true))
        XCTAssertEqual(fixture.desired, fixture.actual)
        for _ in 0..<100 { fixture.reconciler.request() }
        fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
    }
    func testRepeatedStartDoesNotDuplicateStartupWork() {
        let fixture = Fixture()
        for _ in 0..<100 { fixture.reconciler.start() }
        XCTAssertEqual(fixture.pending.count, 1)
        fixture.drain()
        XCTAssertEqual(fixture.applies, 1)
    }
}
