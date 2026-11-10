import Foundation
import CoreFoundation
import IOKit.ps

@MainActor private final class PowerSourceContext {
    weak var owner:PowerSourceMonitor?
    let generation:UInt64
    init(owner:PowerSourceMonitor,generation:UInt64) {
        self.owner=owner;self.generation=generation
    }
}

/// Event-driven power-source changes, delivered on the main run loop.
/// Construction has no side effects; registration occurs only in start().
@MainActor final class PowerSourceMonitor {
    private var source:CFRunLoopSource?
    private var context:Unmanaged<PowerSourceContext>?
    private var generation:UInt64=0
    private var onChange:(()->Void)?
    private(set) var running=false

    @discardableResult func start(onChange:@escaping()->Void)->Bool {
        stop()
        let retained=Unmanaged.passRetained(PowerSourceContext(owner:self,generation:generation))
        guard let candidate=IOPSNotificationCreateRunLoopSource({raw in
            guard let raw else{return}
            let context=Unmanaged<PowerSourceContext>.fromOpaque(raw).takeUnretainedValue()
            MainActor.assumeIsolated {context.owner?.receive(generation:context.generation)}
        },retained.toOpaque())?.takeRetainedValue() else {
            retained.release();return false
        }
        self.onChange=onChange;source=candidate;context=retained;running=true
        CFRunLoopAddSource(CFRunLoopGetMain(),candidate,.commonModes)
        return true
    }
    func stop() {
        generation &+= 1;running=false;onChange=nil
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source=nil;context?.release();context=nil
    }
    private func receive(generation expected:UInt64) {
        guard running,generation==expected else{return}
        onChange?()
    }
    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        // Destruction is not guaranteed to occur on the actor. Keep callback
        // context alive until the main run loop can finish any in-flight delivery.
        if let context {DispatchQueue.main.async {context.release()}}
    }
}
