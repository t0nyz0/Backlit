import XCTest
@testable import Backlit

/// Saved-pause messages are shown on the main page and in the menu, next to
/// the Logo on switch. "This setting" there points at the wrong control.
final class LidPauseWordingTests: XCTestCase {
    func testEveryPauseMessageStandsOnItsOwnOutsideSettings() {
        let pauses = [LidSavedPause(reason: .hardFault), LidSavedPause(reason: .legacyUnknown),
                      LidSavedPause(reason: .interruptedCleanup), LidSavedPause(reason: .interruptedCleanup, attempts: LidSavedPause.attemptLimit)]
        for pause in pauses {
            XCTAssertFalse(pause.status.localizedCaseInsensitiveContains("this setting"), pause.status)
            XCTAssertTrue(pause.status.contains("Settings"), "Says where to go: \(pause.status)")
        }
    }

    func testHardPauseNamesTheSwitchAndSaysTheLogoIsOff() {
        let status = LidSavedPause(reason: .hardFault).status
        XCTAssertTrue(status.contains("Keep logo on with lid closed"))
        XCTAssertTrue(status.contains("the logo is off"))
        XCTAssertTrue(status.contains("Restore your light"))
    }

    func testSpecificFaultDetailIsStillPreferred() {
        XCTAssertEqual(LidSavedPause(reason: .hardFault, detail: "Specific detail.").status, "Specific detail.")
    }
}
