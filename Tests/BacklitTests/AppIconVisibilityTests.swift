import Foundation
import XCTest
@testable import Backlit

@MainActor final class AppIconVisibilityTests: XCTestCase {
    private final class Item {}
    @MainActor private final class Backend {
        var dock = true
        var canShowDock = true
        var canHideDock = true
        var canCreateMenu = true
        var policyChangesState = true
        var events: [String] = []
        var created = 0
        var removed = 0
        let menu = MenuBarItemController<Item>()
        var menuAvailable: Bool { menu.item != nil }
        func makeController() -> AppIconVisibilityController {
            AppIconVisibilityController(dockIsVisible: { self.dock },
                menuBarIsAvailable: { self.menuAvailable }, setDockVisible: { visible in
                    self.events.append(visible ? "dock:on" : "dock:off")
                    guard visible ? self.canShowDock : self.canHideDock else { return false }
                    if self.policyChangesState { self.dock = visible }
                    return true
                }, setMenuBarVisible: { visible in
                    self.events.append(visible ? "menu:on" : "menu:off")
                    if visible && !self.canCreateMenu { return }
                    self.menu.setVisible(visible, create: { self.created += 1; return Item() },
                        remove: { _ in self.removed += 1 })
                })
        }
    }
    private func defaults() -> (String, UserDefaults) {
        let name = "Backlit.AppIconVisibility." + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }
    func testLaunchDoesNotSpeculativelyRequestDockOrPostUntrackedFailure() throws {
        // Launch wiring is checked without constructing AppDelegate (which
        // creates real hardware services and windows).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Backlit/main.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(source.range(of: "func application(_ application:", range: launch.upperBound..<source.endIndex))
        let body = source[launch.lowerBound..<end.lowerBound]
        XCTAssertFalse(body.contains("setActivationPolicy"))
        XCTAssertFalse(body.contains("could not show the Dock icon"))
        XCTAssertTrue(body.contains("model.applyAppIconVisibility()"))
    }

    func testMenuOnlyStartupDoesNotNeedDockAndDoesNotPostFailure() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        store.set(false, forKey: "dockIcon.visible"); store.set(true, forKey: "menuBarIcon.visible")
        let model = AppModel(demo: true, defaults: store)
        let backend = Backend(); backend.dock = false; backend.canShowDock = false
        let controller = backend.makeController()
        model.onAppIconVisibilityChange = { controller.apply($0) }
        model.applyAppIconVisibility()
        XCTAssertEqual(backend.events, ["menu:on"])
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.dockIconVisible); XCTAssertTrue(model.menuBarIconVisible)
    }

    func testEveryRequestedPairHasAtLeastOneEntry() {
        for dock in [true, false] {
            for menu in [true, false] {
                let backend = Backend(), controller = backend.makeController()
                let result = controller.apply(.init(dock: dock, menuBar: menu))
                XCTAssertTrue(result.visibility.hasVisibleEntry)
                XCTAssertEqual(result.visibility, AppIconVisibility(dock: dock, menuBar: menu).normalized)
                XCTAssertNil(result.failure)
            }
        }
    }
    func testMenuIsCreatedBeforeDockIsHiddenAndRepeatedApplicationIsIdempotent() {
        let backend = Backend(), controller = backend.makeController()
        for _ in 0..<100 {
            let result = controller.apply(.init(dock: false, menuBar: true))
            XCTAssertEqual(result.visibility, .init(dock: false, menuBar: true))
        }
        XCTAssertEqual(Array(backend.events.prefix(2)), ["menu:on", "dock:off"])
        XCTAssertEqual(backend.created, 1)
        XCTAssertEqual(backend.events.filter { $0 == "dock:off" }.count, 1)
    }
    func testDockIsRestoredBeforeMenuRemoval() {
        let backend = Backend(), controller = backend.makeController()
        _ = controller.apply(.init(dock: false, menuBar: true))
        backend.events.removeAll()
        let result = controller.apply(.init(dock: false, menuBar: false))
        XCTAssertEqual(backend.events, ["dock:on", "menu:off"])
        XCTAssertEqual(result.visibility, .init(dock: true, menuBar: false))
        XCTAssertEqual(backend.removed, 1)
    }
    func testFailedDockRestoreNeverRemovesTheExistingMenu() {
        let backend = Backend(), controller = backend.makeController()
        _ = controller.apply(.init(dock: false, menuBar: true))
        backend.events.removeAll(); backend.canShowDock = false
        let result = controller.apply(.init(dock: true, menuBar: false))
        XCTAssertEqual(backend.events, ["dock:on"])
        XCTAssertEqual(result.visibility, .init(dock: false, menuBar: true))
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(backend.removed, 0)
    }
    func testMenuCreationFailureKeepsDockAndNeverAttemptsToHideIt() {
        let backend = Backend(); backend.canCreateMenu = false
        let result = backend.makeController().apply(.init(dock: false, menuBar: true))
        XCTAssertEqual(result.visibility, .init(dock: true, menuBar: false))
        XCTAssertNotNil(result.failure)
        XCTAssertFalse(backend.events.contains("dock:off"))
    }
    func testMenuFailureRestoresDockIfItWasAlreadyHidden() {
        let backend = Backend(); backend.dock = false; backend.canCreateMenu = false
        let result = backend.makeController().apply(.init(dock: false, menuBar: true))
        XCTAssertEqual(backend.events, ["menu:on", "dock:on"])
        XCTAssertEqual(result.visibility, .init(dock: true, menuBar: false))
        XCTAssertNotNil(result.failure)
    }
    func testFailedHideAndFalseSuccessBothReportActualState() {
        for refuses in [true, false] {
            let backend = Backend(); backend.canHideDock = !refuses; backend.policyChangesState = false
            let result = backend.makeController().apply(.init(dock: false, menuBar: true))
            XCTAssertEqual(result.visibility, .init(dock: true, menuBar: true))
            XCTAssertNotNil(result.failure)
            XCTAssertEqual(backend.created, 1)
        }
    }
    func testRepeatedModeSwitchesNeverDuplicateOrLeakMenuItems() {
        let backend = Backend(), controller = backend.makeController()
        for _ in 0..<100 {
            for requested in [AppIconVisibility(dock: false, menuBar: true),
                              AppIconVisibility(dock: true, menuBar: false),
                              AppIconVisibility(dock: true, menuBar: true)] {
                XCTAssertTrue(controller.apply(requested).visibility.hasVisibleEntry)
            }
        }
        XCTAssertNotNil(backend.menu.item)
        XCTAssertEqual(backend.created, 101)
        XCTAssertEqual(backend.removed, 100)
    }
    func testMissingAndMalformedPreferencesDefaultToMenuBarOnly() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        for malformed in [nil, "hidden", Data([1]), 0, 42] as [Any?] {
            store.set(malformed, forKey: "dockIcon.visible")
            store.set(malformed, forKey: "menuBarIcon.visible")
            XCTAssertEqual(AppIconVisibility.load(store), .init(dock: false, menuBar: true))
        }
    }
    func testFreshAndUpgradedMenuEnabledPreferencesDefaultToHiddenDock() {
        for priorMenuChoice in [nil, true] as [Bool?] {
            let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
            store.set(priorMenuChoice, forKey: "menuBarIcon.visible")
            XCTAssertNil(store.object(forKey: "dockIcon.visible"))
            let model = AppModel(demo: true, defaults: store)
            XCTAssertFalse(model.dockIconVisible); XCTAssertTrue(model.menuBarIconVisible)
            let backend = Backend(), controller = backend.makeController()
            model.onAppIconVisibilityChange = { controller.apply($0) }
            model.applyAppIconVisibility()
            XCTAssertEqual(backend.events, ["menu:on", "dock:off"])
            XCTAssertFalse(store.bool(forKey: "dockIcon.visible"))
            let reopened = AppModel(demo: true, defaults: store)
            XCTAssertFalse(reopened.dockIconVisible); XCTAssertTrue(reopened.menuBarIconVisible)
        }
    }
    func testUpgradedHiddenMenuChoiceStaysHiddenWithVisibleDock() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        store.set(false, forKey: "menuBarIcon.visible")
        XCTAssertNil(store.object(forKey: "dockIcon.visible"))
        let model = AppModel(demo: true, defaults: store)
        XCTAssertTrue(model.dockIconVisible); XCTAssertFalse(model.menuBarIconVisible)
        let backend = Backend(), controller = backend.makeController()
        model.onAppIconVisibilityChange = { controller.apply($0) }
        model.applyAppIconVisibility()
        XCTAssertEqual(backend.events, ["menu:off"])
        XCTAssertFalse(store.bool(forKey: "menuBarIcon.visible"))
        XCTAssertTrue(store.bool(forKey: "dockIcon.visible"))
        let reopened = AppModel(demo: true, defaults: store)
        XCTAssertTrue(reopened.dockIconVisible); XCTAssertFalse(reopened.menuBarIconVisible)
    }
    func testExplicitDockAndMenuChoicesSurviveExceptAnUnsafeBothHiddenPair() {
        for dock in [false, true] {
            for menu in [false, true] {
                let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
                store.set(dock, forKey: "dockIcon.visible"); store.set(menu, forKey: "menuBarIcon.visible")
                let model = AppModel(demo: true, defaults: store)
                XCTAssertEqual(model.menuBarIconVisible, menu)
                XCTAssertEqual(model.dockIconVisible, dock || !menu)
                XCTAssertEqual(store.bool(forKey: "menuBarIcon.visible"), menu)
                XCTAssertEqual(store.bool(forKey: "dockIcon.visible"), dock || !menu)
            }
        }
    }
    func testMalformedOrMissingDockPreferenceDoesNotOverrideAnExplicitHiddenMenu() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        store.set(false, forKey: "menuBarIcon.visible")
        for malformed in [nil, "hidden", Data([1]), 0, 42] as [Any?] {
            store.set(malformed, forKey: "dockIcon.visible")
            XCTAssertEqual(AppIconVisibility.load(store), .init(dock: true, menuBar: false))
            XCTAssertFalse(store.bool(forKey: "menuBarIcon.visible"))
        }
    }
    func testStartupRepairsBothHiddenPreferencesWithoutChangingOtherSettings() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        store.set(false, forKey: "dockIcon.visible"); store.set(false, forKey: "menuBarIcon.visible")
        store.set(0.31, forKey: "brightness"); store.set("steady", forKey: "mode")
        store.set("keep", forKey: "unrelated.fixture")
        let model = AppModel(demo: true, defaults: store)
        XCTAssertTrue(model.dockIconVisible); XCTAssertFalse(model.menuBarIconVisible)
        XCTAssertTrue(store.bool(forKey: "dockIcon.visible"))
        XCTAssertEqual(model.brightness, 0.31); XCTAssertEqual(model.mode, .steady)
        XCTAssertEqual(store.string(forKey: "unrelated.fixture"), "keep")
    }
    func testModelPersistsAppliedValuesAndRestoresUIAfterRejectedMenuHiding() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: store)
        let backend = Backend(), controller = backend.makeController()
        model.onAppIconVisibilityChange = { controller.apply($0) }
        model.applyAppIconVisibility()
        model.dockIconVisible = false
        XCTAssertFalse(model.dockIconVisible); XCTAssertTrue(model.menuBarIconVisible)
        backend.canShowDock = false
        model.menuBarIconVisible = false
        XCTAssertFalse(model.dockIconVisible); XCTAssertTrue(model.menuBarIconVisible)
        XCTAssertFalse(store.bool(forKey: "dockIcon.visible"))
        XCTAssertTrue(store.bool(forKey: "menuBarIcon.visible"))
        XCTAssertNotNil(model.notice)
        let reopened = AppModel(demo: true, defaults: store)
        XCTAssertFalse(reopened.dockIconVisible); XCTAssertTrue(reopened.menuBarIconVisible)
        backend.canShowDock = true
        model.menuBarIconVisible = false
        XCTAssertTrue(model.dockIconVisible); XCTAssertFalse(model.menuBarIconVisible)
        XCTAssertNil(model.notice)
    }
    func testReentrantNativeCallbackDoesNotReapplyOrPersistTemporaryValues() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: "dockIcon.visible")
        let model = AppModel(demo: true, defaults: store)
        var calls = 0
        model.onAppIconVisibilityChange = { requested in
            calls += 1; model.menuBarIconVisible = false
            return AppIconVisibilityResult(visibility: requested)
        }
        model.dockIconVisible = false
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(model.dockIconVisible); XCTAssertTrue(model.menuBarIconVisible)
        XCTAssertFalse(store.bool(forKey: "dockIcon.visible"))
        XCTAssertTrue(store.bool(forKey: "menuBarIcon.visible"))
    }

    func testTotalNativeFailureDoesNotSaveAnInaccessibleLaunchPreference() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: "dockIcon.visible"); store.set(true, forKey: "menuBarIcon.visible")
        let model = AppModel(demo: true, defaults: store)
        let backend = Backend(); backend.dock = false; backend.canShowDock = false; backend.canCreateMenu = false
        let controller = backend.makeController()
        model.onAppIconVisibilityChange = { controller.apply($0) }
        model.dockIconVisible = false
        XCTAssertFalse(model.dockIconVisible); XCTAssertFalse(model.menuBarIconVisible)
        XCTAssertNotNil(model.notice)
        XCTAssertTrue(store.bool(forKey: "dockIcon.visible"))
        XCTAssertTrue(store.bool(forKey: "menuBarIcon.visible"))
    }
    func testVisibilityChangesPreserveLightAndConnectionPreferencesWithoutHardwareCalls() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        let values: [String: Any] = ["brightness": 0.42, "mode": "steady", "enabled": true,
            "mcp.access": "control", "bridge.enabled": true, "bridge.lan": false,
            "agent.folder.codex": "/tmp/inert-codex-folder", "unrelated.fixture": "keep"]
        for (key, value) in values { store.set(value, forKey: key) }
        let model = AppModel(demo: true, defaults: store,
            hardwareRestore: { XCTFail("Visibility must not restore hardware") },
            hardwareApply: { _, _ in XCTFail("Visibility must not apply hardware"); return .applied })
        let before = store.dictionaryRepresentation()
        for _ in 0..<100 {
            model.dockIconVisible = false
            model.menuBarIconVisible = false
            model.menuBarIconVisible = true
        }
        for key in values.keys {
            XCTAssertEqual(store.object(forKey: key) as? NSObject, before[key] as? NSObject, key)
        }
        XCTAssertEqual(model.brightness, 0.42); XCTAssertEqual(model.mode, .steady)
        XCTAssertEqual(model.mcpAccess, .control); XCTAssertTrue(model.enabled)
    }

    func testVisibilityChangesPreserveSettingsSelectionAndTheExistingOpenWindowRoute() {
        let (suite, store) = defaults(); defer { store.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: store)
        let backend = Backend(), controller = backend.makeController()
        model.onAppIconVisibilityChange = { controller.apply($0) }
        model.selectedPage = "settings"
        var opens = 0
        model.openWindow = { opens += 1 }
        model.applyAppIconVisibility()
        for _ in 0..<100 {
            model.menuBarIconVisible = false
            model.menuBarIconVisible = true
            model.dockIconVisible = false
        }
        backend.canShowDock = false
        model.menuBarIconVisible = false
        XCTAssertEqual(opens, 0, "Icon changes must not open or replace a window")
        XCTAssertEqual(model.selectedPage, "settings")
        XCTAssertNotNil(model.openWindow)
        model.openWindow?()
        XCTAssertEqual(opens, 1, "The existing reopen route remains installed")
        XCTAssertEqual(model.selectedPage, "settings")
    }
}
