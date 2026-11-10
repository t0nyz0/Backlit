import AppKit

enum StatusIconGeometry {
    static let lid = CGRect(x: 3, y: 4.5, width: 14, height: 14)
    static let interior = lid.insetBy(dx: 0.65, dy: 0.65)

    static func step(for output: Double) -> Int {
        let level = Effects.clamp(output)
        return level == 0 ? 0 : max(1, Int((level * 100).rounded()))
    }

    static func marker(at step: Int) -> CGRect? {
        guard step > 0 else { return nil }
        // Area follows output; the minimum size keeps 1% legible at 1x scale.
        let side = min(interior.width, max(1.8, interior.width * CGFloat(sqrt(Double(min(step, 100)) / 100))))
        return CGRect(x: interior.midX - side / 2, y: interior.midY - side / 2, width: side, height: side)
    }

    static func image(at step: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 22), flipped: false) { _ in
            if let marker = marker(at: step) {
                let fraction = CGFloat(min(max(step, 0), 100)) / 100
                let radius = min(marker.width / 2, 1.8 + (1 - fraction) * 4)
                NSColor.black.withAlphaComponent(0.9).setFill()
                NSBezierPath(roundedRect: marker, xRadius: radius, yRadius: radius).fill()
            }
            // Stroke last: the outline stays readable at both endpoints.
            NSColor.black.withAlphaComponent(0.78).setStroke()
            let outline = NSBezierPath(roundedRect: lid, xRadius: 2.4, yRadius: 2.4)
            outline.lineWidth = 1.1
            outline.stroke()
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 2, y: 3))
            base.line(to: NSPoint(x: 18, y: 3))
            base.lineWidth = 1
            base.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
