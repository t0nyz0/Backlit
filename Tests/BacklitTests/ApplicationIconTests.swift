import AppKit
import XCTest
@testable import Backlit

@MainActor
final class ApplicationIconTests: XCTestCase {
    private func fixture(iconName: String?) throws -> (Bundle, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("IconFixture.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": "local.backlit.icon-test." + UUID().uuidString,
            "CFBundleName": "IconFixture", "CFBundlePackageType": "APPL"
        ]
        if let iconName { info["CFBundleIconFile"] = iconName }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try XCTUnwrap(Bundle(url: app)), resources, root)
    }

    private func png(red: Bool) throws -> Data {
        let pixel: [UInt8] = red ? [255, 0, 0, 255] : [0, 0, 255, 255]
        let bytes = Data((0..<16).flatMap { _ in pixel })
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 16, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil,
                                         shouldInterpolate: false, intent: .defaultIntent))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    private func color(_ image: NSImage?) throws -> NSColor {
        let image = try XCTUnwrap(image)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
    }

    func testUsesTheDeclaredBundleResourceWithOrWithoutExtension() throws {
        for name in ["CurrentIcon", "CurrentIcon.icns"] {
            let (bundle, resources, _) = try fixture(iconName: name)
            try png(red: true).write(to: resources.appendingPathComponent("CurrentIcon.icns"))
            let loaded = try color(ApplicationIcon.load(bundle: bundle))
            XCTAssertGreaterThan(loaded.redComponent, 0.99)
            XCTAssertLessThan(loaded.blueComponent, 0.01)
        }
    }

    func testReloadReadsChangedBytesInsteadOfNamedImageCache() throws {
        let (bundle, resources, _) = try fixture(iconName: "CurrentIcon")
        let path = resources.appendingPathComponent("CurrentIcon.icns")
        try png(red: true).write(to: path)
        XCTAssertGreaterThan(try color(ApplicationIcon.load(bundle: bundle)).redComponent, 0.99)
        try png(red: false).write(to: path)
        let refreshed = try color(ApplicationIcon.load(bundle: bundle))
        XCTAssertGreaterThan(refreshed.blueComponent, 0.99)
        XCTAssertLessThan(refreshed.redComponent, 0.01)
    }

    func testMissingOrInvalidResourceLeavesTheSystemIconAlone() throws {
        let (noName, _, _) = try fixture(iconName: nil)
        XCTAssertNil(ApplicationIcon.load(bundle: noName))
        let (bundle, resources, _) = try fixture(iconName: "Missing")
        XCTAssertNil(ApplicationIcon.load(bundle: bundle))
        try Data("not an image".utf8).write(to: resources.appendingPathComponent("Missing.icns"))
        XCTAssertNil(ApplicationIcon.load(bundle: bundle))
    }
}
