import AppKit
import XCTest
@testable import Backlit

@MainActor final class PreviewMarkTests: XCTestCase {
    private final class MarkFixture: NSView {
        var level = 0.0
        var compact = false
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill(); bounds.fill()
            PreviewLightMark.draw(level: level, in: bounds, compact: compact)
        }
    }
    private func render(_ level: Double, compact: Bool) throws -> NSBitmapImageRep {
        let view = MarkFixture(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        view.level = level; view.compact = compact
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    private func brightness(_ rep: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> CGFloat {
        let scale = CGFloat(rep.pixelsWide) / 160
        let color = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
    func testFullAndMenuMarksRemainFixedCenteredSquares() {
        for compact in [false, true] {
            for bounds in [CGRect(x: 0, y: 0, width: 88, height: 60), CGRect(x: 13, y: 7, width: 295, height: 174)] {
                let square = PreviewLightMark.square(in: bounds, compact: compact)
                XCTAssertEqual(square.width, square.height)
                XCTAssertEqual(square.midX, bounds.midX)
                XCTAssertEqual(square.midY, bounds.midY)
                XCTAssertTrue(bounds.contains(square))
                XCTAssertEqual(square.width, compact ? 8 : 18)
            }
        }
    }
    func testSquareCornersSurviveOffLowMidAndHighOutputWithoutPillRounding() throws {
        for compact in [false, true] {
            let square = PreviewLightMark.square(in: CGRect(x: 0, y: 0, width: 160, height: 120), compact: compact)
            for level in [0.0, 0.01, 0.5, 1] {
                let rep = try render(level, compact: compact)
                for x in [square.minX + 1, square.maxX - 2] {
                    for y in [square.minY + 1, square.maxY - 2] {
                        let corner = try brightness(rep, x: x, y: y)
                        XCTAssertGreaterThan(corner, level == 1 ? 0.9 : 0.075, "A square must fill all four corners, including dim output")
                    }
                }
                let center = try brightness(rep, x: square.midX, y: square.midY)
                let outside = try brightness(rep, x: square.maxX + 2, y: square.midY)
                XCTAssertGreaterThan(center, outside, "Glow must not erase the square edge")
            }
        }
    }
    func testHaloDoesNotHaveAnUnpaintedCircularCenterAndRejectsExtremeLevels() throws {
        for compact in [false, true] {
            let off = try render(0, compact: compact), high = try render(1, compact: compact)
            let square = PreviewLightMark.square(in: CGRect(x: 0, y: 0, width: 160, height: 120), compact: compact)
            for offset in stride(from: square.height/2 + 2, through: compact ? 18 : 40, by: 2) {
                XCTAssertGreaterThan(try brightness(high, x: 80, y: 60 + offset), try brightness(off, x: 80, y: 60 + offset))
                XCTAssertGreaterThan(try brightness(high, x: 80, y: 60 - offset), try brightness(off, x: 80, y: 60 - offset))
            }
            for bad in [Double.nan, .infinity, -.infinity, -1, Double.greatestFiniteMagnitude] {
                let rep = try render(bad, compact: compact)
                let center = try brightness(rep, x: 80, y: 60)
                XCTAssertTrue(center.isFinite && (0...1).contains(center))
            }
        }
    }
    @MainActor func testHiddenPreviewStopsPublishingButEffectOutputKeepsAdvancing() {
        let suite = "local.backlit.test.preview-hidden." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        model.mode = .steady; model.brightness = 0.25
        model.isPreviewVisible = { false }
        model.tick()
        XCTAssertEqual(model.output, 0.25)
        XCTAssertEqual(model.presentation.level, 0)
        model.isPreviewVisible = { true }
        model.tick()
        XCTAssertEqual(model.presentation.level, 0.25)
        model.isPreviewVisible = { false }; model.brightness = 0.9
        model.tick()
        XCTAssertEqual(model.output, 0.9)
        XCTAssertEqual(model.presentation.level, 0.25)
        XCTAssertTrue(model.prepareQuit())
    }

    @MainActor func testVisualPolicyDeniesUnavailableDisplaysAndRecoversOnSessionReturn() async {
        for bits in 0..<16 {
            let allowed = VisualUpdatePolicy.allows(locked: bits & 1 != 0, screenSleeping: bits & 2 != 0,
                systemSleeping: bits & 4 != 0, consoleActive: bits & 8 == 0)
            XCTAssertEqual(allowed, bits == 0)
        }
        let suite = "local.backlit.test.visual-policy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        model.start()
        XCTAssertTrue(model.visualUpdatesAllowed)
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(model.visualUpdatesAllowed)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.visualUpdatesAllowed)
        XCTAssertTrue(model.prepareQuit())
    }

}
