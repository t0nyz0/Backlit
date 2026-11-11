import Foundation

/// A source bound to the polling thread. Generation changes are recorded before
/// signaling, and the pending bit survives a source handled before wait begins.
final class FadeSafetyWake: @unchecked Sendable {
    private let lock=NSLock()
    private let loop:CFRunLoop
    private var source:CFRunLoopSource?
    private var pending=false
    static func makeSource() -> CFRunLoopSource? {
        var context=CFRunLoopSourceContext();context.perform={_ in}
        return CFRunLoopSourceCreate(kCFAllocatorDefault,0,&context)
    }
    init(sourceFactory:()->CFRunLoopSource? = FadeSafetyWake.makeSource) throws {
        loop=CFRunLoopGetCurrent()
        guard let source=sourceFactory() else {throw RuntimeServices.failure("Safety-event wake observation is unavailable.")}
        self.source=source
        CFRunLoopAddSource(loop,source,.defaultMode)
    }
    func signal() {
        lock.lock();defer{lock.unlock()}
        guard let source else{return}
        pending=true;CFRunLoopSourceSignal(source);CFRunLoopWakeUp(loop)
    }
    private func consume() -> Bool {
        lock.lock();defer{lock.unlock()}
        guard source != nil,pending else{return false}
        pending=false;return true
    }
    @discardableResult func wait(_ interval:Double) -> Bool {
        guard interval.isFinite,interval>0 else{return false}
        guard CFEqual(loop,CFRunLoopGetCurrent()) else {Thread.sleep(forTimeInterval:interval);return false}
        let deadline=ProcessInfo.processInfo.systemUptime+interval
        while true {
            if consume(){return true}
            lock.lock();let active=source != nil;lock.unlock()
            guard active else{return false}
            let remaining=deadline-ProcessInfo.processInfo.systemUptime
            guard remaining>0 else{return false}
            let result=CFRunLoopRunInMode(.defaultMode,remaining,true)
            if result == .finished || result == .stopped {
                if consume(){return true}
                let delay=deadline-ProcessInfo.processInfo.systemUptime
                if delay>0 {Thread.sleep(forTimeInterval:delay)}
                return consume()
            }
        }
    }
    func invalidate() {
        lock.lock();defer{lock.unlock()}
        if let source {CFRunLoopSourceInvalidate(source)}
        source=nil;pending=false
    }
    deinit {invalidate()}
}
