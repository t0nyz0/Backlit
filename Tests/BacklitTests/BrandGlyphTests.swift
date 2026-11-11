import AppKit
import SwiftUI
import XCTest
@testable import Backlit

@MainActor
final class BrandGlyphTests: XCTestCase {
    private func render(size: Int) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: BrandGlyph(size: CGFloat(size)))
        renderer.scale = 1
        renderer.isOpaque = false
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    private func rgb(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
    }

    func testSquareIsCenteredAndLegibleAtEveryIconSize() throws {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let image = try render(size: size)
            let center = try rgb(image, size / 2, size / 2)
            XCTAssertGreaterThan(center.redComponent, 0.90, "Center at \(size)")
            XCTAssertGreaterThan(center.alphaComponent, 0.99, "Center alpha at \(size)")
            var xs: [Int] = [], ys: [Int] = []
            for y in size / 3..<(2 * size / 3) {
                for x in size / 3..<(2 * size / 3) {
                    let color = try rgb(image, x, y)
                    if color.redComponent > 0.90 && color.greenComponent > 0.90
                        && color.blueComponent > 0.90 && color.alphaComponent > 0.99 {
                        xs.append(x); ys.append(y)
                    }
                }
            }
            let minX = try XCTUnwrap(xs.min()), maxX = try XCTUnwrap(xs.max())
            let minY = try XCTUnwrap(ys.min()), maxY = try XCTUnwrap(ys.max())
            XCTAssertEqual(maxX - minX, maxY - minY, accuracy: 1, "Square at \(size)")
            XCTAssertEqual(Double(minX + maxX + 1) / 2, Double(size) / 2, accuracy: 0.6)
            XCTAssertEqual(Double(minY + maxY + 1) / 2, Double(size) / 2, accuracy: 0.6)
        }
    }

    func testOldTopBarIsAbsentAndCornersAreTransparent() throws {
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let image = try render(size: size)
            let oldBar = try rgb(image, size / 2, Int(Double(size) * 0.38))
            XCTAssertLessThan(oldBar.redComponent, 0.75, "Old white bar at \(size)")
            for (x, y) in [(0, 0), (size - 1, 0), (0, size - 1), (size - 1, size - 1)] {
                XCTAssertLessThan(try rgb(image, x, y).alphaComponent, 0.01)
            }
        }
    }
}
