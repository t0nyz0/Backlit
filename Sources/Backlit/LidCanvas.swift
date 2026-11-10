import SwiftUI
import AppKit

enum BacklitPalette {
    static let canvas = Color(nsColor:NSColor(name:nil,dynamicProvider:{ appearance in
        appearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? NSColor(white:0.105,alpha:1) : NSColor(red:0.975,green:0.972,blue:0.965,alpha:1)
    }))
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
            let glow=NSGradient(colors:[NSColor.white.withAlphaComponent(level*0.28),NSColor.white.withAlphaComponent(0)])!
            glow.draw(fromCenter:NSPoint(x:rect.midX,y:rect.midY+4),radius:6,toCenter:NSPoint(x:rect.midX,y:rect.midY+4),radius:95,options:.drawsAfterEndingLocation)
            // Original Backlit light marker, not Apple's trademark logo.
            let marker=NSBezierPath(roundedRect:NSRect(x:rect.midX-16,y:rect.midY-4,width:32,height:8),xRadius:4,yRadius:4)
            context.saveGraphicsState()
            let halo=NSShadow();halo.shadowColor=NSColor.white.withAlphaComponent(level*0.8);halo.shadowBlurRadius=16;halo.shadowOffset = .zero;halo.set()
            NSColor.white.withAlphaComponent(0.1+Effects.clamp(level)*0.9).setFill();marker.fill()
            context.restoreGraphicsState();context.restoreGraphicsState()
            let hinge=NSBezierPath();hinge.move(to:NSPoint(x:rect.minX+25,y:rect.minY+5));hinge.line(to:NSPoint(x:rect.maxX-25,y:rect.minY+5));hinge.lineWidth=0.7;NSColor.white.withAlphaComponent(0.17).setStroke();hinge.stroke()
        }
    }
}
