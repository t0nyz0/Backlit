import XCTest
@testable import Backlit

@MainActor final class ControlCenterPowerTests: XCTestCase {
    func testNativePowerUsesExistingAdmissionWithoutEnablingPublicAutomations() throws {
        let suite = "local.backlit.test.controlcenter." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("steady", forKey: "mode")
        let ready = ExternalControlContext(hardwareAvailable: true, controlWanted: true,
            controlling: true, availableModes: GlowMode.allCases)
        let model = AppModel(demo: true, defaults: defaults, externalControlObservation: { ready })
        XCTAssertFalse(model.automationsEnabled)
        try model.performControlCenterPower(false)
        XCTAssertFalse(model.enabled)
        try model.performControlCenterPower(true)
        XCTAssertTrue(model.enabled)
        XCTAssertFalse(model.automationsEnabled)
        XCTAssertEqual(model.mode, .steady)
        XCTAssertTrue(model.prepareQuit())
    }

    func testRecoveryBusyUnsupportedAndPausedOnDoNotMutatePreferences() throws {
        for failure in ["recovery", "busy", "unsupported", "paused", "unowned"] {
            let suite = "local.backlit.test.controlcenter." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(false, forKey: "enabled")
            defaults.set("steady", forKey: "mode")
            var context = ExternalControlContext(hardwareAvailable: true, controlWanted: true,
                controlling: true, availableModes: GlowMode.allCases)
            switch failure {
            case "recovery": context.needsRecovery = true
            case "busy": context.busy = true
            case "unsupported": context.hardwareAvailable = false
            case "paused": context.paused = "Display asleep"
            default: context.controlWanted = false
            }
            let model = AppModel(demo: true, defaults: defaults, externalControlObservation: { context })
            XCTAssertThrowsError(try model.performControlCenterPower(true), failure)
            XCTAssertFalse(model.enabled, failure)
            XCTAssertFalse(defaults.bool(forKey: "enabled"), failure)
            XCTAssertFalse(model.automationsEnabled, failure)
            XCTAssertTrue(model.prepareQuit())
        }
    }

    func testPreviewCannotBeMistakenForRealControlOrHardwareState() throws {
        let suite = "local.backlit.test.controlcenter." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        XCTAssertThrowsError(try model.performControlCenterPower(false))
        let state = model.controlCenterObservation()
        XCTAssertFalse(state.available)
        XCTAssertFalse(state.effective)
        XCTAssertEqual(state.requested, model.enabled)
        XCTAssertTrue(model.prepareQuit())
    }
}
