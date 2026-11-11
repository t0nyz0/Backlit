import AppKit
import SwiftUI

/// Compile with Sources/Backlit/BrandGlyph.swift so asset generation cannot
/// silently diverge from the native in-app artwork.
@main
struct RenderIcon {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "BacklitIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected an output directory."])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let set = root.appendingPathComponent("Backlit.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let representations: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        for (name, pixels) in representations {
            try render(pixels: pixels, to: set.appendingPathComponent(name))
        }
        try render(pixels: 1024, to: root.appendingPathComponent("icon-master.png"))
        try render(pixels: 512, to: root.appendingPathComponent("icon.png"))
    }

    @MainActor
    private static func render(pixels: Int, to destination: URL) throws {
        let renderer = ImageRenderer(content: BrandGlyph(size: CGFloat(pixels)))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "BacklitIcon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not render the native icon."])
        }
        try png.write(to: destination, options: .atomic)
    }
}
