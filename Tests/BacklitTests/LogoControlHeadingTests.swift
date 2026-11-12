import AppKit
import SwiftUI
import XCTest
@testable import Backlit

@MainActor final class LogoControlHeadingTests: XCTestCase {
    private func render(status: String, detail: String = "Compatible illuminated logo detected",
                        width: CGFloat = 600, active: Bool = true) throws -> CGImage {
        let view = LogoControlHeading(title: "LOGO CONTROL", status: status,
            detail: detail, controlling: active)
            .foregroundStyle(.white.opacity(0.85)).padding(18)
            .frame(width: width, alignment: .leading)
            .background(Color(white: 0.12))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.cgImage)
    }

    func testShortStatusAndCompatibilityFitAtTheTop() throws {
        for state in ["Glowing", "Logo off", "Waiting for light output", "Reconnecting to your MacBook"] {
            let image = try render(status: state)
            XCTAssertEqual(image.width, 1200)
            XCTAssertGreaterThan(image.height, 80)
            XCTAssertLessThan(image.height, 150, "Short state belongs beside the heading")
        }
    }

    func testLongRecoveryMessageWrapsInsteadOfBeingTruncated() throws {
        let message = "Logo control unavailable: The requested logo endpoint was not confirmed. Restore your light before retrying."
        let wide = try render(status: message, width: 650, active: false)
        let narrow = try render(status: message, width: 360, active: false)
        XCTAssertEqual(narrow.width, 720)
        XCTAssertGreaterThan(narrow.height, try render(status: "Glowing", width: 360).height)
        XCTAssertGreaterThanOrEqual(narrow.height, wide.height)
        XCTAssertLessThan(narrow.height, 380, "The header must remain usable at narrow widths")
    }

    func testCompatibilityExplanationCanWrapIndependently() throws {
        let ordinary = try render(status: "Connecting to your MacBook", width: 360, active: false)
        let unavailable = try render(status: "Connecting to your MacBook",
            detail: "The logo control service is unavailable on this version of macOS. No compatible illuminated logo was detected.",
            width: 360, active: false)
        XCTAssertGreaterThan(unavailable.height, ordinary.height)
    }

    func testHeaderReadsCurrentStatusWithoutChangingControlOrPreferences() {
        let suite = "local.backlit.test.heading." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        let before = defaults.dictionaryRepresentation()
        let preview = LogoPreview(model: model)
        XCTAssertEqual(preview.statusHeading.title, "LIVE PREVIEW")
        XCTAssertEqual(preview.statusHeading.status, model.status)
        XCTAssertFalse(preview.statusHeading.controlling)
        model.pausedReason = "Waiting for light output"
        XCTAssertEqual(preview.statusHeading.status, "Waiting for light output")
        model.pausedReason = "Paused while your Mac cools down"
        XCTAssertEqual(preview.statusHeading.status, "Paused while your Mac cools down")
        XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before as NSDictionary)
        XCTAssertFalse(model.controlWanted); XCTAssertFalse(model.controlling)
    }

    func testOptionalOffscreenVisualFixtures() throws {
        guard let output = ProcessInfo.processInfo.environment["BACKLIT_UI_QA_OUTPUT"] else { return }
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples: [(String, String, Bool)] = [
            ("glowing", "Glowing", true),
            ("waiting", "Waiting for light output", false),
            ("off", "Logo off", true),
            ("recovery", "Logo control unavailable: The requested logo endpoint was not confirmed. Restore your light before retrying.", false)
        ]
        let narrow = NSBitmapImageRep(cgImage: try render(status: samples[3].1, width: 360, active: false))
        try XCTUnwrap(narrow.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("heading-recovery-narrow.png"))
        for (name, status, active) in samples {
            let view = VStack(alignment: .leading, spacing: 12) {
                LogoControlHeading(title: "LOGO CONTROL", status: status,
                    detail: "Compatible illuminated logo detected", controlling: active)
                    .foregroundStyle(.white.opacity(0.85))
                Divider().overlay(.white.opacity(0.15))
                Text("Isolated native UI fixture · no hardware state or control")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }.padding(18).frame(width: 650).background(Color(white: 0.12))
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("heading-\(name).png"))
        }
    }
}
