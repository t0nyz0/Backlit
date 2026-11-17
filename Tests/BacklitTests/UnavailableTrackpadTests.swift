import XCTest
@testable import Backlit

@MainActor final class UnavailableTrackpadTests: XCTestCase {
    private func fixture(savedMode: String = "touch", typing: Bool = false,
                         sources: [TouchSource] = [], _ test: (AppModel, UserDefaults) throws -> Void) rethrows {
        let suite = "local.backlit.test.unavailable-trackpad." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(savedMode, forKey: "mode")
        defaults.set(typing, forKey: "typing.enabled")
        let model = AppModel(demo: true, defaults: defaults, touchSources: sources)
        defer { XCTAssertTrue(model.prepareQuit()); defaults.removePersistentDomain(forName: suite) }
        try test(model, defaults)
    }
    func testSavedUnavailableTrackpadStaysSelectedAndDark() {
        fixture { model, defaults in
            XCTAssertEqual(model.mode, .touch)
            XCTAssertEqual(defaults.string(forKey: "mode"), "touch")
            XCTAssertEqual(model.effectOutput(at: 0), 0)
            XCTAssertFalse(model.availableModes.contains(.touch))
            XCTAssertTrue(model.presentedModes.contains(.touch))
            XCTAssertNotNil(model.unavailableTouchMessage)
        }
    }
    func testLastSourceDisableKeepsSelectionVisibleWithoutEnablingSteady() {
        fixture(typing: true) { model, defaults in
            XCTAssertEqual(model.mode, .touch)
            XCTAssertTrue(model.availableModes.contains(.touch))
            XCTAssertNil(model.unavailableTouchMessage)
            model.typingEnabled = false
            XCTAssertEqual(model.mode, .touch)
            XCTAssertFalse(model.availableModes.contains(.touch))
            XCTAssertTrue(model.presentedModes.contains(.touch))
            XCTAssertNotNil(model.unavailableTouchMessage)
            XCTAssertEqual(model.effectOutput(at: 0), 0)
            XCTAssertEqual(defaults.string(forKey: "mode"), "touch")
            model.typingEnabled = true
            XCTAssertTrue(model.availableModes.contains(.touch))
            XCTAssertNil(model.unavailableTouchMessage)
        }
    }
    func testSwitchingAwayHidesUnavailableOptionAndDoesNotReenableTyping() {
        fixture(typing: true) { model, defaults in
            model.typingEnabled = false
            model.mode = .breathe
            XCTAssertEqual(model.mode, .breathe)
            XCTAssertFalse(model.presentedModes.contains(.touch))
            XCTAssertFalse(model.availableModes.contains(.touch))
            XCTAssertNil(model.unavailableTouchMessage)
            XCTAssertFalse(defaults.bool(forKey: "typing.enabled"))
        }
    }
    func testAvailableNativeSourceIsUnchangedByTypingDisable() {
        fixture(typing: true, sources: [.trackpad]) { model, _ in
            model.typingEnabled = false
            XCTAssertEqual(model.mode, .touch)
            XCTAssertTrue(model.availableModes.contains(.touch))
            XCTAssertEqual(model.presentedModes, model.availableModes)
            XCTAssertNil(model.unavailableTouchMessage)
        }
    }
    func testExternalAdmissionStillRejectsUnavailableTrackpad() throws {
        try fixture(typing: true) { model, _ in
            model.typingEnabled = false
            let state = model.agentLightState()
            XCTAssertFalse(state.availableModes.first(where: { $0.name == "trackpad" })!.selectable)
            XCTAssertNotNil(state.availableModes.first(where: { $0.name == "trackpad" })!.reason)
            var context = ExternalControlContext()
            context.hardwareAvailable = true; context.controlWanted = true; context.controlling = true
            context.availableModes = model.availableModes
            XCTAssertThrowsError(try context.validate(LightCommand(mode: .touch))) { error in
                XCTAssertEqual((error as? ExternalControlError)?.code, .invalidArgument)
            }
        }
    }
}
