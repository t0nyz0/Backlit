import XCTest
@testable import Backlit

@MainActor final class MenuBarVisibilityTests: XCTestCase {
    private final class Item {}
    func testDefaultAndMalformedPreferencesKeepRecoveryVisible() {
        for malformed in [nil, "hidden", Data([1])] as [Any?] {
            let suite = "local.backlit.test.tray." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(malformed, forKey: "menuBarIcon.visible")
            let model = AppModel(demo: true, defaults: defaults)
            XCTAssertTrue(model.menuBarIconVisible)
            XCTAssertTrue(model.prepareQuit())
            defaults.removePersistentDomain(forName: suite)
        }
    }
    func testPreferenceSurvivesRelaunchWithoutChangingUnrelatedSettings() {
        let suite = "local.backlit.test.tray." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.25, forKey: "brightness"); defaults.set("battery", forKey: "mode")
        defaults.set("keep", forKey: "unrelated.fixture")
        let first = AppModel(demo: true, defaults: defaults)
        var callbacks = 0; first.onMenuBarIconVisibilityChange = { callbacks += 1 }
        first.menuBarIconVisible = false; first.menuBarIconVisible = false
        XCTAssertEqual(callbacks, 1)
        XCTAssertTrue(first.prepareQuit())
        let reopened = AppModel(demo: true, defaults: defaults)
        XCTAssertFalse(reopened.menuBarIconVisible)
        XCTAssertEqual(reopened.brightness, 0.25); XCTAssertEqual(reopened.mode, .battery)
        XCTAssertEqual(defaults.string(forKey: "unrelated.fixture"), "keep")
        reopened.menuBarIconVisible = true
        XCTAssertTrue(defaults.bool(forKey: "menuBarIcon.visible"))
        XCTAssertTrue(reopened.prepareQuit())
    }
    func testRepeatedTogglesOwnAtMostOneItemAndReleaseIt() {
        let controller = MenuBarItemController<Item>()
        var created = 0, removed = 0
        weak var last: Item?
        for _ in 0..<1000 {
            for _ in 0..<3 {
                controller.setVisible(true, create: { created += 1; let item = Item(); last = item; return item }, remove: { _ in XCTFail() })
            }
            XCTAssertNotNil(controller.item)
            for _ in 0..<3 {
                controller.setVisible(false, create: { XCTFail(); return Item() }, remove: { _ in
                    XCTAssertNil(controller.item)
                    removed += 1
                })
            }
            XCTAssertNil(last)
        }
        XCTAssertEqual(created, 1000); XCTAssertEqual(removed, 1000)
    }
    func testPersistedHiddenStateDoesNotCreateAnItemOnNewController() {
        let first = MenuBarItemController<Item>()
        XCTAssertFalse(first.setVisible(false, create: { XCTFail(); return Item() }, remove: { _ in XCTFail() }))
        let relaunched = MenuBarItemController<Item>()
        XCTAssertTrue(relaunched.setVisible(true, create: { Item() }, remove: { _ in XCTFail() }))
        XCTAssertNotNil(relaunched.item)
    }
}
