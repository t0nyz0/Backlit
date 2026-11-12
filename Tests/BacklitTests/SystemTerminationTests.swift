import AppKit
import Carbon
import XCTest
@testable import Backlit

/// Synthetic AppleEvents and injected restoration only. These tests never
/// send an event, terminate an app, change power settings, or access hardware.
@MainActor final class SystemTerminationTests: XCTestCase {
    private final class StoppedWatcher: LidWatcherProcess {
        var isRunning: Bool { false }
        var terminationStatus: Int32 = 0
        func terminate() { XCTFail("The inert helper already exited") }
    }

    private func event(reason: OSType? = nil,
                       eventClass: AEEventClass = AEEventClass(kCoreEventClass),
                       eventID: AEEventID = AEEventID(kAEQuitApplication)) -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID,
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        if let reason {
            result.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason))
        }
        return result
    }

    private func makeModel(stopper: LidWatcherStopper? = nil,
                           hardwareRestore: @escaping () throws -> Void) -> AppModel {
        let suite = "local.backlit.test.system-termination." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults,
            lidStopper: stopper ?? LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false }),
            hardwareRestore: hardwareRestore)
        model.enabled = false; model.controlWanted = true; model.controlling = true
        return model
    }

    func testDocumentedLogoutRestartAndShutdownReasonsSkipOnlyOffConfirmation() {
        for code in [kAEReallyLogOut, kAERestart, kAEShutDown] {
            let reason = QuitReason(appleEvent: event(reason: OSType(code)))
            XCTAssertEqual(reason, .systemSessionEnd)
            XCTAssertFalse(reason.requiresOffConfirmation)
        }
    }

    func testMissingUnknownAndNonSessionQuitReasonsKeepConfirmation() {
        XCTAssertEqual(QuitReason(appleEvent: nil), .userInitiated)
        XCTAssertEqual(QuitReason(appleEvent: event()), .userInitiated)
        // Requesting a system dialog is not itself a committed session end.
        for code in [kAEQuitAll, kAELogOut, kAEShowRestartDialog, kAEShowShutdownDialog, 0] {
            let reason = QuitReason(appleEvent: event(reason: OSType(code)))
            XCTAssertEqual(reason, .userInitiated)
            XCTAssertTrue(reason.requiresOffConfirmation)
        }
    }

    func testSessionReasonOnUnrelatedEventDoesNotBypassConfirmation() {
        XCTAssertEqual(QuitReason(appleEvent: event(reason: OSType(kAEShutDown), eventClass: 0)), .userInitiated)
        XCTAssertEqual(QuitReason(appleEvent: event(reason: OSType(kAEShutDown), eventID: AEEventID(kAEOpenApplication))), .userInitiated)
        let attributeOnly = event()
        attributeOnly.setAttribute(NSAppleEventDescriptor(enumCode: OSType(kAEShutDown)),
            forKeyword: AEKeyword(kAEQuitReason))
        XCTAssertEqual(QuitReason(appleEvent: attributeOnly), .userInitiated,
            "The quit reason is an AppleEvent parameter, not an attribute")
    }

    func testMalformedReasonKeepsConfirmation() {
        let malformed = event()
        malformed.setParam(NSAppleEventDescriptor(string: "shutdown"), forKeyword: AEKeyword(kAEQuitReason))
        XCTAssertEqual(QuitReason(appleEvent: malformed), .userInitiated)
    }

    func testExplicitQuitStillAllowsOffConfirmationToCancel() {
        var restores = 0, confirmations = 0
        let model = makeModel { restores += 1 }
        XCTAssertFalse(model.prepareQuit(confirmOff: {
            confirmations += 1
            return .alertSecondButtonReturn
        }))
        XCTAssertEqual(confirmations, 1); XCTAssertEqual(restores, 0)
        XCTAssertTrue(model.controlling); XCTAssertTrue(model.lifecycleAllowsFrames)
        XCTAssertTrue(model.prepareQuit(confirmOff: { .alertFirstButtonReturn }))
        XCTAssertEqual(restores, 1)
    }

    func testSystemQuitRestoresOffLogoWithoutPresentingConfirmation() {
        var restores = 0
        let model = makeModel { restores += 1 }
        XCTAssertTrue(model.prepareQuit(reason: .systemSessionEnd, confirmOff: {
            XCTFail("System termination must not show the optional Off-logo warning")
            return .alertSecondButtonReturn
        }))
        XCTAssertEqual(restores, 1); XCTAssertFalse(model.controlling)
        XCTAssertFalse(model.lifecycleAllowsFrames)
    }

    func testSystemQuitStillCancelsWhenNativeRestorationFails() {
        var restores = 0, fail = true
        let model = makeModel {
            restores += 1
            if fail { throw NSError(domain: "fixture.system-quit-restore", code: 1) }
        }
        XCTAssertFalse(model.prepareQuit(reason: .systemSessionEnd, confirmOff: {
            XCTFail("System termination must not show the optional Off-logo warning")
            return .alertFirstButtonReturn
        }))
        XCTAssertEqual(restores, 1); XCTAssertTrue(model.controlling)
        XCTAssertNotNil(model.error)
        fail = false
        XCTAssertTrue(model.prepareQuit(reason: .systemSessionEnd))
        XCTAssertEqual(restores, 2); XCTAssertFalse(model.controlling)
    }

    func testSystemQuitWaitsForHelperAndNativeRestorationBeforeApproval() async {
        let watcher = StoppedWatcher()
        var restores = 0
        let model = makeModel { restores += 1 }
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/inert-system-quit-lease")))
        let reason = QuitReason(appleEvent: event(reason: OSType(kAEShutDown)))
        let done = expectation(description: "System termination waits for verified cleanup")
        model.onLidStopCompleted = { safe in
            XCTAssertTrue(safe); XCTAssertEqual(restores, 1)
            XCTAssertFalse(model.controlling)
            XCTAssertTrue(model.prepareQuit(reason: reason, confirmOff: {
                XCTFail("The captured reason remains valid after the AppleEvent callback")
                return .alertSecondButtonReturn
            }))
            done.fulfill()
        }
        defer { model.onLidStopCompleted = nil }
        XCTAssertFalse(model.prepareQuit(reason: reason, confirmOff: {
            XCTFail("System termination must not show the optional Off-logo warning")
            return .alertSecondButtonReturn
        }))
        XCTAssertTrue(model.lidStopPending); XCTAssertEqual(restores, 0)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(model.lidStopPending)
    }

    func testSystemQuitStillRejectsFailedHelperRestoration() async {
        let watcher = StoppedWatcher(); watcher.terminationStatus = 6
        var restores = 0
        let model = makeModel { restores += 1 }
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/inert-system-quit-failure-lease")))
        let done = expectation(description: "Failed helper restoration blocks system termination")
        model.onLidStopCompleted = { safe in
            XCTAssertFalse(safe); XCTAssertEqual(restores, 0)
            done.fulfill()
        }
        defer { model.onLidStopCompleted = nil }
        XCTAssertFalse(model.prepareQuit(reason: .systemSessionEnd))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(model.controlling); XCTAssertFalse(model.lifecycleAllowsFrames)
        XCTAssertNotNil(model.error)
        // Retire inert fixture ownership only; no repair process is launched.
        XCTAssertTrue(model.completePowerRecovery {})
        model.controlling = false
        XCTAssertTrue(model.prepareQuit())
    }

    func testSystemQuitRejectsNativeRestoreFailureAfterHelperExit() async {
        let watcher = StoppedWatcher()
        var restores = 0, fail = true
        let model = makeModel {
            restores += 1
            if fail { throw NSError(domain: "fixture.system-quit-async-restore", code: 1) }
        }
        XCTAssertTrue(model.adoptLidWatcher(watcher, lease: URL(fileURLWithPath: "/tmp/inert-system-quit-native-failure-lease")))
        let done = expectation(description: "Native restoration must succeed after helper exit")
        model.onLidStopCompleted = { safe in
            XCTAssertFalse(safe); XCTAssertEqual(restores, 1)
            done.fulfill()
        }
        defer { model.onLidStopCompleted = nil }
        XCTAssertFalse(model.prepareQuit(reason: .systemSessionEnd))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(model.controlling); XCTAssertNotNil(model.error)
        fail = false
        XCTAssertTrue(model.prepareQuit(reason: .systemSessionEnd))
        XCTAssertEqual(restores, 2); XCTAssertFalse(model.controlling)
    }
}
