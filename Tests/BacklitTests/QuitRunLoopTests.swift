import AppKit
import XCTest
@testable import Backlit

/// Reproduce the CLI quit entry without creating an application or touching hardware.
@MainActor final class QuitRunLoopTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // NSApplication normally adds its modal mode to the common modes.
        // These fixtures never create an application, so mirror that setup.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.modalPanel.rawValue as CFString))
    }

    private final class StoppedWatcher: LidWatcherProcess {
        var isRunning: Bool { false }
        var terminationStatus: Int32 { 0 }
        func terminate() { XCTFail("The inert process already exited") }
    }

    func testRunLoopQuitCompletesHelperAndMappingCleanupInsideModalLoop() async {
        let suite = "local.backlit.test.quit-runloop." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let process = StoppedWatcher()
        var restores = 0
        let model = AppModel(demo: true, defaults: defaults, lidStopper: stopper,
            hardwareRestore: { restores += 1 })
        model.controlling = true; model.controlWanted = true
        XCTAssertTrue(model.adoptLidWatcher(process, lease: URL(fileURLWithPath: "/tmp/inert-quit-lease")))
        let scheduler = QuitRunLoop()
        var completed = false, entries = 0
        model.onLidStopCompleted = { safe in
            XCTAssertTrue(safe)
            XCTAssertEqual(restores, 1, "Native mapping cleanup precedes termination approval")
            XCTAssertFalse(model.controlling)
            XCTAssertTrue(model.prepareQuit())
            completed = true
        }
        defer { model.onLidStopCompleted = nil }
        let done = expectation(description: "Run-loop scheduled quit finishes without a second Quit")
        DispatchQueue.main.async {
            scheduler.request {
                entries += 1
                XCTAssertFalse(model.prepareQuit())
                let deadline = Date(timeIntervalSinceNow: 1)
                let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
                RunLoop.current.add(timer, forMode: .modalPanel)
                while Date() < deadline && !completed {
                    _ = RunLoop.current.run(mode: .modalPanel, before: deadline)
                }
                timer.invalidate()
                XCTAssertTrue(completed, "Cleanup must finish during the first nested termination loop")
                done.fulfill()
            }
            scheduler.request { XCTFail("Duplicate pending quit should be coalesced") }
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(entries, 1)
        XCTAssertEqual(restores, 1)
        XCTAssertFalse(model.lidStopPending)
        XCTAssertFalse(model.controlling)
    }

    func testMainQueueNestedModalLoopCannotDeliverStopperContinuation() async {
        let stopper = LidWatcherStopper(removeLease: { _ in }, needsRecovery: { _ in false })
        let process = StoppedWatcher()
        var completed = false
        let callback = expectation(description: "Continuation runs after the main queue entry returns")
        stopper.onResult = { result in
            XCTAssertTrue(result.safeToQuit)
            completed = true
            callback.fulfill()
        }
        let nested = expectation(description: "Nested modal loop returns")
        DispatchQueue.main.async {
            XCTAssertTrue(stopper.requestStop(process: process, lease: nil,
                journal: URL(fileURLWithPath: "/tmp/inert-quit-journal")))
            let deadline = Date(timeIntervalSinceNow: 0.1)
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { _ in }
            RunLoop.current.add(timer, forMode: .modalPanel)
            while Date() < deadline && !completed {
                _ = RunLoop.current.run(mode: .modalPanel, before: deadline)
            }
            timer.invalidate()
            XCTAssertFalse(completed, "A main-queue entry cannot recursively drain its own queue")
            nested.fulfill()
        }
        await fulfillment(of: [nested, callback], timeout: 2)
    }
}
