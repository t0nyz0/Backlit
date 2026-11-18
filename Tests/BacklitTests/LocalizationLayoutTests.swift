import XCTest
import SwiftUI
import AppKit
@testable import Backlit

/// Builds only offscreen views. Never opens a window, captures the desktop, or
/// starts a real device session. Optional artifacts are rendered from these views.
@MainActor final class LocalizationLayoutTests: XCTestCase {
    func testEveryLanguageConstructsMinimumWidthWorkspaceAndMenu() throws {
        _ = NSApplication.shared
        for language in AppLanguage.allCases {
            let suite = "local.backlit.test.locale-layout." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = AppModel(demo: true, defaults: defaults)
            model.language = language.rawValue
            for appearance in ["light", "dark"] {
            model.appearance = appearance
            let nativeAppearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)!
            var workspace: NSHostingView<RootView>!
            for page in ["light", "connections", "settings"] {
                model.selectedPage = page
                workspace = NSHostingView(rootView: RootView(model: model))
                workspace.appearance = nativeAppearance
                workspace.frame = NSRect(x: 0, y: 0, width: 1020, height: 760)
                workspace.layoutSubtreeIfNeeded()
                XCTAssertTrue(workspace.fittingSize.width.isFinite, "\(language.rawValue): \(page)")
                if let directory = ProcessInfo.processInfo.environment["BACKLIT_LOCALIZATION_SNAPSHOTS"] {
                    let folder = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try snapshot(workspace, to: folder.appendingPathComponent("\(page)-\(language.rawValue)-\(appearance).png"))
                }
            }
            let menu = NSHostingView(rootView: MenuView(model: model))
            menu.appearance = nativeAppearance
            let menuSize = menu.fittingSize
            XCTAssertTrue(menuSize.width.isFinite && menuSize.height.isFinite, language.rawValue)
            XCTAssertGreaterThan(menuSize.height, 0, language.rawValue)
            menu.frame = NSRect(origin: .zero, size: NSSize(width: 320, height: max(1, menuSize.height)))
            menu.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["BACKLIT_LOCALIZATION_SNAPSHOTS"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try snapshot(menu, to: folder.appendingPathComponent("menu-\(language.rawValue)-\(appearance).png"))
                // A full content view makes safety text inspectable beyond the
                // normal settings scroll viewport without changing app geometry.
                let settings = NSHostingView(rootView: SettingsPage(model: model).padding(34).frame(width: 750).preferredColorScheme(model.colorScheme).environment(\.locale, model.formattingLocale))
                settings.appearance = nativeAppearance
                settings.frame = NSRect(origin: .zero, size: NSSize(width:750,height: max(1,settings.fittingSize.height)))
                settings.layoutSubtreeIfNeeded()
                try snapshot(settings, to: folder.appendingPathComponent("settings-full-\(language.rawValue)-\(appearance).png"))
            }
            // Render the long recovery state independently of hardware mutation.
            // This is the same wrapping heading used by the live logo preview.
            let recovery = NSHostingView(rootView: LogoControlHeading(
                title: model.l("LOGO CONTROL"),
                status: model.l("Restoration was requested. Native handback remains unconfirmed, so the saved closed-lid choice stays paused."),
                detail: model.l("Maximum 30 minutes per closure. Sleep counts toward the timer; relaunching does not reset it. This limit does not guarantee safe temperatures."),
                controlling: false).padding(18).frame(width:320).background(Color.black).foregroundStyle(.white).preferredColorScheme(model.colorScheme))
            recovery.appearance = nativeAppearance
            recovery.frame = NSRect(origin:.zero,size:recovery.fittingSize)
            recovery.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(recovery.fittingSize.height, 40)
            if let directory = ProcessInfo.processInfo.environment["BACKLIT_LOCALIZATION_SNAPSHOTS"] {
                try snapshot(recovery, to: URL(fileURLWithPath:directory).appendingPathComponent("recovery-\(language.rawValue)-\(appearance).png"))
            }
            }
            XCTAssertTrue(model.prepareQuit())
        }
    }

    func testMenuPreviewAccessibilityTracksPresentationOnlyChanges() {
        let presentation = LightPresentation()
        let preview = MenuLidPreview(presentation: presentation, language: .french)
        presentation.level = 0.15
        let first = preview.accessibilityText
        presentation.level = 0.80
        let second = preview.accessibilityText
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains("15"))
        XCTAssertTrue(second.contains("80"))
        XCTAssertEqual(second, Localization.format(Localization.text("Logo preview, {value} percent", language: .french), arguments:["value":"80"]))
    }

    private func snapshot(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Offscreen bitmap unavailable: \(url.lastPathComponent)"); return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Offscreen PNG unavailable: \(url.lastPathComponent)"); return
        }
        try data.write(to: url)
    }
}
