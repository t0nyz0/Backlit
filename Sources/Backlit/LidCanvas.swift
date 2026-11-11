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
    func updateNSView(_ view: Drawing, context: Context) {
        guard view.level != level else { return }
        view.level = level; view.needsDisplay = true
    }
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
    func updateNSView(_ view:Drawing,context:Context){
        guard view.level != level || view.compact != compact else { return }
        view.level=level;view.compact=compact;view.needsDisplay=true
    }
    final class Drawing:NSView {
        var level:Double=0.5
        var compact=false
        private struct CacheKey: Equatable {
            let bounds: NSRect
            let scale: CGFloat
            let compact: Bool
            let appearance: String
        }
        private var cachedKey: CacheKey?
        private var cachedBackground: NSBitmapImageRep?
        override var isOpaque:Bool {true}
        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            cachedKey=nil;cachedBackground=nil;needsDisplay=true
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            cachedKey=nil;cachedBackground=nil;needsDisplay=true
        }
        private var lidRect: NSRect {
            let width:CGFloat=compact ? 225:295, height:CGFloat=compact ? 132:174
            return NSRect(x:bounds.midX-width/2,y:bounds.midY-height/2+2,width:width,height:height)
        }
        private func background() -> NSBitmapImageRep? {
            let scale=window?.backingScaleFactor ?? 1
            guard bounds.width>0,bounds.height>0,scale.isFinite,scale>0 else{return nil}
            let key=CacheKey(bounds:bounds,scale:scale,compact:compact,appearance:effectiveAppearance.name.rawValue)
            if cachedKey==key {return cachedBackground}
            let width=ceil(bounds.width*scale),height=ceil(bounds.height*scale)
            // Bound allocation for pathological resize requests; direct drawing
            // remains the fallback and is visually identical.
            guard width.isFinite,height.isFinite,width<=8192,height<=8192,
                  width*height<=16_777_216,
                  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(width),pixelsHigh:Int(height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
                  let context=NSGraphicsContext(bitmapImageRep:bitmap) else{return nil}
            bitmap.size=bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current=context
            context.cgContext.scaleBy(x:scale,y:scale)
            context.cgContext.translateBy(x:-bounds.minX,y:-bounds.minY)
            drawBackground()
            NSGraphicsContext.restoreGraphicsState()
            cachedKey=key;cachedBackground=bitmap
            return bitmap
        }
        override func draw(_ dirtyRect:NSRect) {
            if let bitmap=background() {bitmap.draw(in:bounds)} else {drawBackground()}
            guard let context=NSGraphicsContext.current else{return}
            let rect=lidRect
            context.saveGraphicsState()
            NSBezierPath(roundedRect:rect,xRadius:13,yRadius:13).addClip()
            PreviewLightMark.draw(level:level,in:rect,compact:false)
            context.restoreGraphicsState()
            drawHinge(in:rect)
        }
        private func drawBackground() {
            guard let context=NSGraphicsContext.current else{return}
            context.cgContext.setBlendMode(.normal)
            NSGradient(starting:NSColor(white:0.145,alpha:1),ending:NSColor(white:0.045,alpha:1))!.draw(in:bounds,angle:-65)
            let rect=lidRect
            context.saveGraphicsState()
            let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.55);shadow.shadowBlurRadius=22;shadow.shadowOffset=NSSize(width:0,height:-10);shadow.set()
            let lid=NSBezierPath(roundedRect:rect,xRadius:13,yRadius:13)
            NSColor(white:0.19,alpha:1).setFill();lid.fill()
            context.restoreGraphicsState()
            NSGradient(starting:NSColor(white:0.30,alpha:1),ending:NSColor(white:0.155,alpha:1))!.draw(in:lid,angle:-65)
            NSColor.white.withAlphaComponent(0.24).setStroke();lid.lineWidth=0.7;lid.stroke()
        }
        private func drawHinge(in rect:NSRect) {
            let hinge=NSBezierPath();hinge.move(to:NSPoint(x:rect.minX+25,y:rect.minY+5));hinge.line(to:NSPoint(x:rect.maxX-25,y:rect.minY+5));hinge.lineWidth=0.7;NSColor.white.withAlphaComponent(0.17).setStroke();hinge.stroke()
        }
    }
}
