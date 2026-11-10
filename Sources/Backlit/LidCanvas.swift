import SwiftUI
import AppKit

enum BacklitPalette {
    static let canvas = Color(nsColor:NSColor(name:nil,dynamicProvider:{ appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.105,alpha:1) : NSColor(red:0.975,green:0.972,blue:0.965,alpha:1)
    }))
}

/// Fixed square geometry shared by both previews. Output changes intensity,
/// never the shape or position. No color/brightness hardware calls live here.
enum PreviewLightMark {
    static func square(in lid: CGRect, compact: Bool) -> CGRect {
        let side: CGFloat = compact ? 8 : 18
        return CGRect(x: lid.midX - side / 2, y: lid.midY - side / 2, width: side, height: side)
    }
    static func draw(level: Double, in lid: CGRect, compact: Bool) {
        guard let context = NSGraphicsContext.current else { return }
        let amount = Effects.clamp(level)
        let square = square(in: lid, compact: compact)
        let center = NSPoint(x: square.midX, y: square.midY)
        context.saveGraphicsState()
        NSBezierPath(rect: lid).addClip()
        if amount > 0 {
            let glow = NSGradient(starting: NSColor.white.withAlphaComponent(amount * 0.20), ending: NSColor.white.withAlphaComponent(0))!
            // Start at zero and fill before the start: no unpainted circular
            // center, and the halo is concentric with the square itself.
            glow.draw(fromCenter: center, radius: 0, toCenter: center,
                      radius: compact ? 24 : 75,
                      options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.white.withAlphaComponent(amount * 0.45)
        shadow.shadowBlurRadius = compact ? 6 : 10
        shadow.shadowOffset = .zero
        shadow.set()
        NSColor.white.withAlphaComponent(0.10 + amount * 0.90).setFill()
        NSBezierPath(rect: square).fill()
        context.restoreGraphicsState()
    }
}

/// Transparent native overlay keeps the menu's existing lid silhouette.
struct MenuLightMark: NSViewRepresentable {
    var level: Double
    func makeNSView(context: Context) -> Drawing { let view = Drawing(); view.level = level; return view }
    func updateNSView(_ view: Drawing, context: Context) { view.level = level; view.needsDisplay = true }
    final class Drawing: NSView {
        var level = 0.0
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) { PreviewLightMark.draw(level: level, in: bounds, compact: true) }
    }
}

/// Original vector artwork drawn by the app. Uses native drawing so both the
/// on-screen view and owned-view screenshot capture render the same geometry.
struct LidCanvas: NSViewRepresentable {
    var level: Double
    var compact: Bool
    func makeNSView(context:Context)->Drawing {let view=Drawing();view.level=level;view.compact=compact;return view}
    func updateNSView(_ view:Drawing,context:Context){view.level=level;view.compact=compact;view.needsDisplay=true}
    final class Drawing:NSView {
        var level:Double=0.5
        var compact=false
        override var isOpaque:Bool {true}
        override func draw(_ dirtyRect:NSRect) {
            guard let context=NSGraphicsContext.current else{return}
            context.cgContext.setBlendMode(.normal)
            NSGradient(starting:NSColor(white:0.145,alpha:1),ending:NSColor(white:0.045,alpha:1))!.draw(in:bounds,angle:-65)
            let width:CGFloat=compact ? 225:295, height:CGFloat=compact ? 132:174
            let rect=NSRect(x:bounds.midX-width/2,y:bounds.midY-height/2+2,width:width,height:height)
            context.saveGraphicsState()
            let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.55);shadow.shadowBlurRadius=22;shadow.shadowOffset=NSSize(width:0,height:-10);shadow.set()
            let lid=NSBezierPath(roundedRect:rect,xRadius:13,yRadius:13)
            NSColor(white:0.19,alpha:1).setFill();lid.fill()
            context.restoreGraphicsState()
            NSGradient(starting:NSColor(white:0.30,alpha:1),ending:NSColor(white:0.155,alpha:1))!.draw(in:lid,angle:-65)
            NSColor.white.withAlphaComponent(0.24).setStroke();lid.lineWidth=0.7;lid.stroke()
            context.saveGraphicsState();lid.addClip()
            PreviewLightMark.draw(level: level, in: rect, compact: false)
            context.restoreGraphicsState()
            let hinge=NSBezierPath();hinge.move(to:NSPoint(x:rect.minX+25,y:rect.minY+5));hinge.line(to:NSPoint(x:rect.maxX-25,y:rect.minY+5));hinge.lineWidth=0.7;NSColor.white.withAlphaComponent(0.17).setStroke();hinge.stroke()
        }
    }
}
