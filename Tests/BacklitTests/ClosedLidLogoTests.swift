import XCTest
@testable import Backlit

final class ClosedLidLogoTests: XCTestCase {
    final class Fake {
        var daemon: Bool? = true
        var ids: [UInt64]? = [13, 42]
        var events: [String] = []
        var globalSucceeds = true
        var keyboardSucceeds = true
        func make() -> ClosedLidLogo {
            ClosedLidLogo(interface: .init(
                daemonClosed: { self.daemon },
                keyboardIDs: { self.ids },
                setGlobalClosed: { self.events.append("global:\($0)"); return self.globalSucceeds },
                setKeyboardClosed: { self.events.append("keyboard:\($0):\($1)"); return self.keyboardSucceeds }))
        }
    }
    func testRecoveryPrecedesAllWritesAndBothKeyboardsStayClosed() throws {
        let f = Fake(), logo = f.make()
        try logo.enable { f.events.append("journal") }
        XCTAssertEqual(f.events, ["journal", "global:false", "keyboard:13:true", "keyboard:42:true"])
        XCTAssertTrue(logo.active)
    }
    func testRepeatedPollDoesNotRewriteGlobalState() throws {
        let f = Fake(), logo = f.make()
        try logo.enable {}
        let count = f.events.count
        try logo.enable { XCTFail("Already active") }
        XCTAssertEqual(f.events.count, count)
    }
    func testWaitsUntilDaemonObservesClosedLid() throws {
        for state: Bool? in [false, nil] {
            let f = Fake(); f.daemon = state; let logo = f.make()
            try logo.enable { XCTFail("No writes before daemon event") }
            XCTAssertFalse(logo.active)
            XCTAssertTrue(f.events.isEmpty)
        }
    }
    func testUnavailableKeyboardsFailBeforeAnyWrite() {
        for ids: [UInt64]? in [nil, []] {
            let f = Fake(); f.ids = ids; let logo = f.make()
            XCTAssertThrowsError(try logo.enable { XCTFail("Cannot record unsafe session") })
            XCTAssertFalse(logo.active)
            XCTAssertTrue(f.events.isEmpty)
        }
    }
    func testJournalFailurePreventsOverride() {
        let f = Fake(), logo = f.make()
        XCTAssertThrowsError(try logo.enable { throw NSError(domain: "test", code: 1) })
        XCTAssertFalse(logo.active)
        XCTAssertTrue(f.events.isEmpty)
    }
    func testPartialKeyboardFailureRetainsOwnershipForCleanup() throws {
        let f = Fake(); f.keyboardSucceeds = false; let logo = f.make()
        XCTAssertThrowsError(try logo.enable {})
        XCTAssertTrue(logo.active)
        try logo.restore(physicalClosed: true)
        XCTAssertEqual(f.events.last, "global:true")
        XCTAssertFalse(logo.active)
    }
    func testRejectedGlobalWriteStillGetsSafeCleanup() throws {
        let f = Fake(); f.globalSucceeds = false; let logo = f.make()
        XCTAssertThrowsError(try logo.enable {})
        XCTAssertTrue(logo.active)
        f.globalSucceeds = true
        try logo.restore(physicalClosed: true)
        XCTAssertFalse(logo.active)
    }
    func testRestoreUsesCurrentRealLidNotStaleClosedSnapshot() throws {
        let f = Fake(), logo = f.make()
        try logo.enable {}
        try logo.restore(physicalClosed: false)
        XCTAssertEqual(f.events.last, "global:false")
        XCTAssertFalse(logo.active)
    }
    func testUnknownPhysicalLidRetainsRecoveryWithoutGuessing() throws {
        let f = Fake(), logo = f.make()
        try logo.enable {}
        let count = f.events.count
        XCTAssertThrowsError(try logo.restore(physicalClosed: nil))
        XCTAssertTrue(logo.active)
        XCTAssertEqual(f.events.count, count)
    }
    func testFailedRestoreRemainsRetryable() throws {
        let f = Fake(), logo = f.make()
        try logo.enable {}; f.globalSucceeds = false
        XCTAssertThrowsError(try logo.restore(physicalClosed: true))
        XCTAssertTrue(logo.active)
        f.globalSucceeds = true
        try logo.restore(physicalClosed: true)
        XCTAssertFalse(logo.active)
    }
    func testRestoringInactiveSessionDoesNotTouchHardware() throws {
        let f = Fake(), logo = f.make()
        try logo.restore(physicalClosed: true)
        XCTAssertTrue(f.events.isEmpty)
    }
    func testCloseOpenCloseStartsNewRecoverableSession() throws {
        let f = Fake(), logo = f.make()
        try logo.enable {}; try logo.restore(physicalClosed: false)
        f.events.removeAll()
        try logo.enable { f.events.append("new journal") }
        XCTAssertEqual(f.events.first, "new journal")
        XCTAssertTrue(logo.active)
    }
}
