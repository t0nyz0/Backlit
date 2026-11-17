import AppKit
import CoreGraphics
import ApplicationServices

/// Synthetic lifecycle backend for isolated previews/tests. Production always
/// uses ShiftBrightnessKeys and its native permission checks.
struct ShiftBrightnessDriver {
    var start: (Bool) -> String?
    var stop: () -> Void
}

/// Interoperability facts: NX_SYSDEFINED (14), AUX_CONTROL_BUTTONS subtype
/// (8), brightness key types (2/3), and the auxiliary key phase/repeat bits.
/// Ordinary key events and characters are never inspected by this filter.
struct ShiftBrightnessEvent {
    let action: LogoShortcutAction
    let down: Bool
    let repeated: Bool
    let exactShift: Bool
    static func decode(type: UInt, subtype: Int, data1: Int, modifiers: NSEvent.ModifierFlags) -> Self? {
        guard type == NSEvent.EventType.systemDefined.rawValue, subtype == 8 else { return nil }
        let word = UInt32(truncatingIfNeeded:data1)
        let action: LogoShortcutAction
        switch word >> 16 {
        case 2: action = .increase
        case 3: action = .decrease
        default: return nil
        }
        let phase = (word >> 8) & 0xff
        guard phase == 0x0a || phase == 0x0b else { return nil }
        let relevant: NSEvent.ModifierFlags = [.shift,.command,.control,.option,.function]
        return .init(action:action,down:phase == 0x0a,repeated:word & 1 != 0,
                     exactShift:modifiers.intersection(relevant) == .shift)
    }
}

struct ShiftBrightnessDecision: Equatable {
    let consume: Bool
    let action: LogoShortcutAction?
    static let pass = Self(consume:false,action:nil)
}

/// Own an entire matching physical press. Releasing Shift first must not leak
/// its repeats/key-up to the display handler. A gesture started without Shift
/// remains native even if Shift is pressed during that gesture.
struct ShiftBrightnessPolicy {
    private var owned: Set<LogoShortcutAction> = []
    private var native: Set<LogoShortcutAction> = []
    private var lastAction: [LogoShortcutAction:TimeInterval] = [:]
    mutating func reset() { owned.removeAll(); native.removeAll(); lastAction.removeAll() }
    mutating func handle(_ event: ShiftBrightnessEvent?, at now: TimeInterval) -> ShiftBrightnessDecision {
        guard let event else { return .pass }
        if !event.down {
            native.remove(event.action); lastAction.removeValue(forKey:event.action)
            return owned.remove(event.action) == nil ? .pass : .init(consume:true,action:nil)
        }
        if owned.contains(event.action) {
            guard event.repeated, event.exactShift, now.isFinite,
                  now - (lastAction[event.action] ?? now) >= 0.08 else { return .init(consume:true,action:nil) }
            lastAction[event.action] = now
            return .init(consume:true,action:event.action)
        }
        guard !native.contains(event.action), !event.repeated else { return .pass }
        guard event.exactShift, now.isFinite else { native.insert(event.action); return .pass }
        owned.insert(event.action); lastAction[event.action] = now
        return .init(consume:true,action:event.action)
    }
}

/// Physical-gesture ownership and queued-action invalidation form one pure
/// state machine. Recorder boundaries and full listener resets are separate.
struct ShiftBrightnessGestureState {
    private var policy = ShiftBrightnessPolicy()
    private(set) var actionGeneration: UInt64 = 0
    mutating func reset() { actionGeneration &+= 1; policy.reset() }
    // Recorder transitions invalidate queued actions, not a physical key hold.
    // Keep consuming an owned press through its matching key-up.
    mutating func cancelPendingActions() { actionGeneration &+= 1 }
    mutating func handle(_ event: ShiftBrightnessEvent?, at now: TimeInterval) -> ShiftBrightnessDecision {
        policy.handle(event, at: now)
    }
    func acceptsAction(generation: UInt64) -> Bool { actionGeneration == generation }
}

@MainActor private final class ShiftBrightnessTapContext {
    weak var owner: ShiftBrightnessKeys?
    let generation: UInt64
    init(owner: ShiftBrightnessKeys, generation: UInt64) { self.owner = owner; self.generation = generation }
}

/// Explicit opt-in only. This is a session filter for auxiliary brightness
/// events, not a key logger. No display API, event posting, root access or
/// automatic permission request is used. Actual suppression is keyboard/OS
/// dependent and requires physical acceptance before it can be promised.
@MainActor final class ShiftBrightnessKeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: Unmanaged<ShiftBrightnessTapContext>?
    private var generation: UInt64 = 0
    private var gesture = ShiftBrightnessGestureState()
    private(set) var running = false
    private let accessibility: (Bool)->Bool
    private let listeningAccess: ()->Bool
    var onAction: ((LogoShortcutAction)->Void)?
    var onFailure: ((String)->Void)?

    init(accessibility: @escaping (Bool)->Bool = { prompt in
        if prompt { return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary) }
        return AXIsProcessTrusted()
    }, listeningAccess: @escaping ()->Bool = { CGPreflightListenEventAccess() }) {
        self.accessibility = accessibility; self.listeningAccess = listeningAccess
    }

    func start(prompt: Bool) -> String? {
        guard !running else { return nil }
        let trusted = accessibility(prompt)
        guard trusted else { return "Allow Backlit in Accessibility, then enable this option again. Regular shortcuts need no new permission." }
        guard listeningAccess() else {
            return "Allow Backlit in Input Monitoring, then enable this option again. The hardware-key filter stays off until listening access is allowed."
        }
        stop()
        let retained = Unmanaged.passRetained(ShiftBrightnessTapContext(owner:self,generation:generation))
        let mask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        guard let candidate = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,
            options:.defaultTap,eventsOfInterest:mask,callback:{_,type,event,raw in
                guard let raw else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<ShiftBrightnessTapContext>.fromOpaque(raw).takeUnretainedValue()
                let consume = MainActor.assumeIsolated {
                    context.owner?.receive(type,event:event,generation:context.generation) ?? false
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },userInfo:retained.toOpaque()) else {
            retained.release()
            return "macOS did not allow the brightness-key filter. Review Accessibility and Input Monitoring, or use the regular shortcuts."
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,candidate,0) else {
            CFMachPortInvalidate(candidate); retained.release()
            return "The brightness-key filter could not start. Regular shortcuts remain available."
        }
        tap = candidate; self.source = source; context = retained; running = true
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:candidate,enable:true)
        return nil
    }
    func stop() {
        generation &+= 1; running = false; gesture.reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes); CFRunLoopSourceInvalidate(source) }
        if let tap { CFMachPortInvalidate(tap) }
        source = nil; tap = nil; context?.release(); context = nil
    }
    func resetGesture() { gesture.reset() }
    func cancelPendingActions() { gesture.cancelPendingActions() }
    private func receive(_ type: CGEventType, event: CGEvent, generation expected: UInt64) -> Bool {
        guard running, generation == expected else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            running = false; gesture.reset()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == expected else { return }
                self.stop()
                self.onFailure?("macOS stopped hardware-key control. Brightness keys use macOS again; use the regular shortcuts or enable the option again.")
            }
            return false
        }
        guard type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue), let key = NSEvent(cgEvent:event) else { return false }
        let decoded = ShiftBrightnessEvent.decode(type:key.type.rawValue,subtype:Int(key.subtype.rawValue),data1:key.data1,modifiers:key.modifierFlags)
        let decision = gesture.handle(decoded,at:ProcessInfo.processInfo.systemUptime)
        if let action = decision.action {
            let actionGeneration = gesture.actionGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == expected, self.gesture.acceptsAction(generation: actionGeneration) else { return }
                self.onAction?(action)
            }
        }
        return decision.consume
    }
}
