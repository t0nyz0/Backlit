import Foundation
import CoreFoundation

struct AppIconVisibility: Equatable {
    var dock: Bool
    var menuBar: Bool
    var hasVisibleEntry: Bool { dock || menuBar }
    var normalized: Self { menuBar ? self : Self(dock: true, menuBar: false) }

    static func load(_ defaults: UserDefaults) -> Self {
        func boolean(_ key: String) -> Bool? {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        let menuBar = boolean("menuBarIcon.visible") ?? true
        // New/upgrade default: menu bar only. An explicit hidden-menu choice
        // instead needs the Dock, and an explicit Dock choice stays intact.
        let dock = boolean("dockIcon.visible") ?? !menuBar
        return Self(dock: dock, menuBar: menuBar).normalized
    }
}

struct AppIconVisibilityResult {
    let visibility: AppIconVisibility
    var failure: String? = nil
}

/// The delegate supplies AppKit operations; tests supply only inert state.
/// Always establish a usable entry before removing the other one.
@MainActor final class AppIconVisibilityController {
    private let dockIsVisible: () -> Bool
    private let menuBarIsAvailable: () -> Bool
    private let setDockVisible: (Bool) -> Bool
    private let setMenuBarVisible: (Bool) -> Void
    init(dockIsVisible: @escaping () -> Bool, menuBarIsAvailable: @escaping () -> Bool,
         setDockVisible: @escaping (Bool) -> Bool, setMenuBarVisible: @escaping (Bool) -> Void) {
        self.dockIsVisible = dockIsVisible; self.menuBarIsAvailable = menuBarIsAvailable
        self.setDockVisible = setDockVisible; self.setMenuBarVisible = setMenuBarVisible
    }
    private var actual: AppIconVisibility {
        AppIconVisibility(dock: dockIsVisible(), menuBar: menuBarIsAvailable())
    }
    func isApplied(_ requested: AppIconVisibility) -> Bool {
        actual == requested.normalized
    }
    private func showDock() -> Bool {
        if dockIsVisible() { return true }
        let accepted = setDockVisible(true)
        return accepted && dockIsVisible()
    }
    private func failed(_ message: String) -> AppIconVisibilityResult {
        if !actual.hasVisibleEntry {
            setMenuBarVisible(true)
            if !menuBarIsAvailable() { _ = showDock() }
        }
        return AppIconVisibilityResult(visibility: actual, failure: actual.hasVisibleEntry ? message :
            "macOS could not make an app icon available. Keep this window open and retry.")
    }
    func apply(_ requested: AppIconVisibility) -> AppIconVisibilityResult {
        let desired = requested.normalized
        if desired.menuBar {
            setMenuBarVisible(true)
            guard menuBarIsAvailable() else {
                _ = showDock()
                return failed("Backlit kept its Dock icon because the menu bar icon is unavailable.")
            }
        }
        if desired.dock {
            guard showDock() else {
                return failed("Backlit kept its menu bar icon because macOS could not show the Dock icon.")
            }
            if !desired.menuBar { setMenuBarVisible(false) }
        } else if dockIsVisible() {
            // A stored preference is insufficient: verify the real item/button.
            guard menuBarIsAvailable() else {
                return failed("Backlit kept its Dock icon because the menu bar icon is unavailable.")
            }
            let accepted = setDockVisible(false)
            guard accepted, !dockIsVisible() else {
                return failed("macOS could not change the Dock icon. Backlit's menu bar icon remains available.")
            }
        }
        return AppIconVisibilityResult(visibility: actual)
    }
}
