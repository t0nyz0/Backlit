import AppKit
import SwiftUI
import XCTest
@testable import Backlit

@MainActor final class SidebarNavigationTests: XCTestCase {
    func testPaddingAndTrailingSpaceActivateEachProductionNavigationButton() throws {
        _ = NSApplication.shared
        let suite = "Backlit.SidebarNavigation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        let rows = [("light", "Your light", "sun.max"),
                    ("connections", "Connections", "point.3.connected.trianglepath.dotted"),
                    ("settings", "Settings", "slider.horizontal.3")]
        for (id, title, symbol) in rows {
            let row = RootView(model: model).nav(id, title, symbol)
            let host = NSHostingView(rootView: row)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 156, height: 44),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            window.makeFirstResponder(host)
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 156, height: 44)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            for point in [NSPoint(x: 70, y: 22), NSPoint(x: 145, y: 22), NSPoint(x: 8, y: 22), NSPoint(x: 78, y: 5)] {
                model.selectedPage = "another-page"
                host.layoutSubtreeIfNeeded()
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + 0.01, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 2, clickCount: 1, pressure: 0))
                // Events stay inside this test process and its offscreen window.
                // The queued release also permits AppKit tracking loops to finish.
                NSApplication.shared.postEvent(up, atStart: false)
                window.sendEvent(down)
                if let pending = NSApplication.shared.nextEvent(matching: .leftMouseUp,
                    until: Date(), inMode: .default, dequeue: true) { window.sendEvent(pending) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                XCTAssertEqual(model.selectedPage, id, "\(title) must respond at blank/padded point \(point)")
            }
        }
    }
}
