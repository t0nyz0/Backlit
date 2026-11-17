import XCTest
@testable import Backlit

@MainActor final class GlobalShortcutDisableTests: XCTestCase {
    func testDisableWorksWhenHandlerInstallationIsUnavailableAndLeavesOtherActionsRegistered() throws {
        var next = 0, removed: [Int] = [], handlerCalls = 0
        let registry = LogoShortcutRegistry<Int>(register: { _, _ in next += 1; return next },
                                                 unregister: { removed.append($0) })
        let bindings = Dictionary(uniqueKeysWithValues: LogoShortcutAction.allCases.map { ($0, $0.legacyDefaultBinding) })
        XCTAssertTrue(registry.configure(bindings).isEmpty)
        XCTAssertNoThrow(try LogoShortcutChange.apply(nil, action: .increase, registry: registry, ensureHandler: {
            handlerCalls += 1; throw ShortcutError(message: "Inert handler installation failure")
        }))
        XCTAssertEqual(handlerCalls, 0)
        XCTAssertEqual(removed.count, 1)
        XCTAssertNil(registry.desired[.increase])
        XCTAssertNil(registry.action(signature: LogoShortcutAction.signature, id: LogoShortcutAction.increase.rawValue))
        XCTAssertEqual(registry.action(signature: LogoShortcutAction.signature, id: LogoShortcutAction.toggle.rawValue), .toggle)
        XCTAssertEqual(registry.action(signature: LogoShortcutAction.signature, id: LogoShortcutAction.decrease.rawValue), .decrease)
    }
    func testDisableCanBeSavedAfterStartupHandlerFailureWithoutRegisteringAnything() {
        let suite = "Backlit.ShortcutDisable." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        let registry = LogoShortcutRegistry<Int>(register: { _, _ in XCTFail("Disable must not register"); return 1 },
                                                 unregister: { _ in XCTFail("There is no registration to remove") })
        var handlerCalls = 0
        model.onShortcutChange = { action, binding in
            do {
                try LogoShortcutChange.apply(binding, action: action, registry: registry, ensureHandler: {
                    handlerCalls += 1; throw ShortcutError(message: "Inert unavailable Carbon handler")
                })
                return nil
            } catch { return error.localizedDescription }
        }
        XCTAssertTrue(model.setLogoShortcut(nil, action: .increase))
        XCTAssertNil(model.logoShortcuts[.increase])
        XCTAssertNil(LogoShortcutPreferences.load(defaults)[.increase])
        XCTAssertEqual(handlerCalls, 0)
    }
    func testReplacementStillRequiresHandlerBeforeItCanChangeRegistration() throws {
        var registered = 0, removed = 0, handlerCalls = 0
        let registry = LogoShortcutRegistry<Int>(register: { _, _ in registered += 1; return registered },
                                                 unregister: { _ in removed += 1 })
        try registry.replace(LogoShortcutAction.increase.legacyDefaultBinding, for: .increase)
        let prior = registry.desired[.increase]
        XCTAssertThrowsError(try LogoShortcutChange.apply(.init(keyCode: 45, modifiers: 4352, keyLabel: "N"),
            action: .increase, registry: registry, ensureHandler: {
                handlerCalls += 1; throw ShortcutError(message: "Inert handler failure")
            }))
        XCTAssertEqual(handlerCalls, 1); XCTAssertEqual(registered, 1); XCTAssertEqual(removed, 0)
        XCTAssertEqual(registry.desired[.increase], prior)
    }
}
