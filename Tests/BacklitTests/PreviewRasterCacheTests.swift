import XCTest
import AppKit
@testable import Backlit

@MainActor final class PreviewRasterCacheTests: XCTestCase {
    private final class Reference: NSView {
        var level=0.5
        var compact=false
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
    private func render(_ view:NSView, scale:Int) -> NSBitmapImageRep {
        let size=view.bounds.size
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(size.width)*scale,pixelsHigh:Int(size.height)*scale,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size=size
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        context.cgContext.scaleBy(x:CGFloat(scale),y:CGFloat(scale))
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    func testCachedPreviewMatchesOriginalDrawingAcrossLevelsAndResize() {
        let view=LidCanvas.Drawing(frame:NSRect(x:0,y:0,width:360,height:234))
        let reference=Reference(frame:view.frame)
        for compact in [false,true] {
            view.compact=compact;reference.compact=compact
            for level in [0.0,0.5,1.0] {
                view.level=level;reference.level=level
                let actual=render(view,scale:1),expected=render(reference,scale:1)
                var total=0.0,count=0
                for y in stride(from:0,to:actual.pixelsHigh,by:3) {
                    for x in stride(from:0,to:actual.pixelsWide,by:3) {
                        let a=actual.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                        let b=expected.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
                        total += abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent)
                        count += 3
                    }
                }
                XCTAssertLessThan(total/Double(count),0.01,"Raster cache changed preview at level \(level), compact \(compact)")
            }
        }
        view.setFrameSize(NSSize(width:420,height:260));reference.frame=view.frame
        view.viewDidChangeBackingProperties();view.viewDidChangeEffectiveAppearance()
        let resized=render(view,scale:1)
        XCTAssertEqual(resized.pixelsWide,420);XCTAssertEqual(resized.pixelsHigh,260)
    }
}
