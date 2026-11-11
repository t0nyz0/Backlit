import Foundation
import CoreGraphics
import CoreFoundation

struct TypingPermissionCheck: Equatable {
    let before: Bool
    let requestResult: Bool?
    let after: Bool
    var diagnostic: String {
        let request = requestResult.map { $0 ? "granted" : "not granted" } ?? "not needed"
        return "This running app: access before = \(before ? "allowed" : "denied"); request = \(request); access after = \(after ? "allowed" : "denied")."
    }
}

/// A short inactivity window. It contains timing only, never keyboard content.
struct TypingActivity {
    static let defaultHoldDuration:TimeInterval = 0.18
    var holdDuration:TimeInterval {
        didSet {holdDuration=Self.bounded(holdDuration)}
    }
    private(set) var active=false
    private(set) var deadline:TimeInterval?
    private var lastKeyTime:TimeInterval?

    init(holdDuration:TimeInterval=TypingActivity.defaultHoldDuration) {
        self.holdDuration=Self.bounded(holdDuration)
    }
    static func bounded(_ duration:TimeInterval)->TimeInterval {
        duration.isFinite ? min(0.6,max(0.08,duration)) : defaultHoldDuration
    }
    /// Returns true only when a new typing burst becomes active.
    @discardableResult mutating func keyDown(at time:TimeInterval)->Bool {
        guard time.isFinite,time>=0,lastKeyTime.map({time >= $0}) ?? true else{return false}
        let changed = !active
        active=true;lastKeyTime=time;deadline=time+holdDuration
        return changed
    }
    /// A stale deadline cannot release a burst extended by a later event.
    @discardableResult mutating func expire(at time:TimeInterval)->Bool {
        guard time.isFinite,let deadline,time>=deadline else{return false}
        active=false;self.deadline=nil
        return true
    }
    @discardableResult mutating func reset()->Bool {
        let changed=active
        active=false;deadline=nil;lastKeyTime=nil
        return changed
    }
}

@MainActor private final class TypingTapContext {
    weak var owner:TypingInput?
    let generation:UInt64
    init(owner:TypingInput,generation:UInt64){self.owner=owner;self.generation=generation}
}

/// Opt-in passive key-down timing. No event fields, characters, key codes,
/// application identities, or key-up events are read or retained.
/// Secure-input sessions may suppress events; no bypass or polling is used.
@MainActor final class TypingInput {
    var onActivity:((Bool)->Void)?
    var onStatus:((String)->Void)?
    private(set) var running=false
    private(set) var status="Typing response is off" {
        didSet {if status != oldValue {onStatus?(status)}}
    }
    private let preflightAccess: () -> Bool
    private let requestAccess: () -> Bool
    var permissionGranted:Bool {preflightAccess()}
    init(preflightAccess: @escaping () -> Bool = { CGPreflightListenEventAccess() },
         requestAccess: @escaping () -> Bool = { CGRequestListenEventAccess() }) {
        self.preflightAccess = preflightAccess
        self.requestAccess = requestAccess
    }
    var holdDuration:TimeInterval {
        get {activity.holdDuration}
        set {activity.holdDuration=newValue}
    }
    private var activity=TypingActivity()
    private var tap:CFMachPort?
    private var source:CFRunLoopSource?
    private var context:Unmanaged<TypingTapContext>?
    private var generation:UInt64=0
    private var releaseRevision:UInt64=0
    private var releaseWork:DispatchWorkItem?

    /// Call only from a deliberate user permission action, never during startup.
    @discardableResult func requestPermission()->Bool {
        requestPermissionCheck().after
    }
    /// Explicit user action only. Report the OS request separately from effective access.
    func requestPermissionCheck() -> TypingPermissionCheck {
        let before = permissionGranted
        let request = before ? nil : Optional(requestAccess())
        let check = TypingPermissionCheck(before: before, requestResult: request, after: permissionGranted)
        if !check.after { stop() }
        status = check.after ? "Typing access is allowed" : "macOS still denies Input Monitoring for this running Backlit. Open Input Monitoring and grant access to the installed app, then reopen Backlit."
        return check
    }
    /// Preflights permission; this method never asks macOS for new access.
    @discardableResult func start()->Bool {
        stop()
        guard permissionGranted else {
            status="Input Monitoring permission is required for typing response"
            return false
        }
        let retained=Unmanaged.passRetained(TypingTapContext(owner:self,generation:generation))
        let mask=CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let candidate=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,
            options:.listenOnly,eventsOfInterest:mask,callback:{_,type,event,raw in
                if let raw {
                    let context=Unmanaged<TypingTapContext>.fromOpaque(raw).takeUnretainedValue()
                    // This tap source is attached exclusively to the main run loop.
                    MainActor.assumeIsolated {context.owner?.receive(type,generation:context.generation)}
                }
                return Unmanaged.passUnretained(event)
            },userInfo:retained.toOpaque()) else {
            retained.release();status="Input Monitoring is allowed, but macOS could not create the typing event listener. Reopen Backlit and retry."
            return false
        }
        guard let runLoopSource=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,candidate,0) else {
            CFMachPortInvalidate(candidate);retained.release()
            status="Could not start typing response"
            return false
        }
        tap=candidate;source=runLoopSource;context=retained;running=true
        CFRunLoopAddSource(CFRunLoopGetMain(),runLoopSource,.commonModes)
        CGEvent.tapEnable(tap:candidate,enable:true)
        status="Ready for typing"
        return true
    }
    func stop() {
        generation &+= 1;running=false;reset()
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {CFMachPortInvalidate(tap)}
        source=nil;tap=nil;context?.release();context=nil
        status="Typing response is off"
    }
    /// Clears the current burst while leaving an already authorized tap installed.
    func reset() {
        releaseRevision &+= 1;releaseWork?.cancel();releaseWork=nil
        if activity.reset() {onActivity?(false)}
    }
    private func receive(_ type:CGEventType,generation expected:UInt64) {
        guard running,generation==expected else{return}
        switch type {
        case .keyDown:
            if activity.keyDown(at:ProcessInfo.processInfo.systemUptime) {onActivity?(true)}
            // Repeated input extends the deadline without allocating a task per key.
            if releaseWork == nil {scheduleRelease()}
        case .tapDisabledByTimeout:
            reset()
            guard permissionGranted,let tap else {
                stop();status="Typing access is no longer available"
                return
            }
            CGEvent.tapEnable(tap:tap,enable:true)
        case .tapDisabledByUserInput:
            stop();status="Typing was paused by macOS; turn typing response off and on to resume"
        default:break
        }
    }
    private func scheduleRelease() {
        guard running,let deadline=activity.deadline else{return}
        releaseRevision &+= 1
        let expected=releaseRevision,current=generation
        let work=DispatchWorkItem {[weak self] in
            MainActor.assumeIsolated {
                guard let self,self.running,self.generation==current,self.releaseRevision==expected else{return}
                self.releaseWork=nil
                if self.activity.expire(at:ProcessInfo.processInfo.systemUptime) {self.onActivity?(false)}
                else {self.scheduleRelease()}
            }
        }
        releaseWork=work
        DispatchQueue.main.asyncAfter(deadline:.now()+max(0.001,deadline-ProcessInfo.processInfo.systemUptime),execute:work)
    }
    deinit {
        releaseWork?.cancel()
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {CFMachPortInvalidate(tap)}
        // Keep callback context alive through any main-loop delivery already in flight.
        if let context {DispatchQueue.main.async {context.release()}}
    }
}
