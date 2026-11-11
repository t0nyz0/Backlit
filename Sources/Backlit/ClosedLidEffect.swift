import Foundation
import Darwin

/// Closed displays stop reevaluating the logo brightness mapping. Follow the
/// hardware fade factor instead, only within an owned closed-lid session.
final class ClosedLidEffect {
    struct Sample { let factor: Double; let appliedNits: Double; let multiplier: Double }
    struct Interface {
        var sample: () -> Sample?
        var duration: (Double) -> Bool
        var logicalState: (Int) -> Bool
        var keepKeyboardDark: () -> Bool
        var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
        var frameInterval: Double = 0.05
    }
    private let io: Interface
    private(set) var active = false
    private var direction: Int?
    private var moving = false
    private var holding = false
    private var zeroRiseStartedAt: Double?
    private var zeroBaselineStartedAt: Double?
    private struct EndpointRequest { let target: Double; let startedAt: Double }
    private var pendingEndpoint: EndpointRequest?
    var needsAnimation: Bool { active && (moving || holding || pendingEndpoint != nil) }
    func relinquish() { revision &+= 1; active = false; direction = nil; moving = false; holding = false; zeroRiseStartedAt = nil; zeroBaselineStartedAt = nil; pendingEndpoint = nil }
    init(interface: Interface) { io = interface }

    private var revision: UInt64 = 0
    struct Command { let duration: Double; let state: Int }
    struct Plan {
        fileprivate let owner: ObjectIdentifier
        fileprivate let revision: UInt64
        fileprivate let next: ClosedLidEffect
        let commands: [Command]
        var hasWrites: Bool { !commands.isEmpty }
    }
    /// Capture one sample/time and run the same controller against an inert
    /// recorder. No keyboard or hardware setter can run during planning.
    func plan(_ level: Double, frameInterval: Double = 0.05) throws -> Plan {
        guard frameInterval.isFinite, (0.02...0.2).contains(frameInterval) else {throw RuntimeServices.failure("Invalid effect sampling interval.")}
        let sample=io.sample(), now=io.now()
        var duration=0.0, commands:[Command]=[]
        let next=ClosedLidEffect(interface:.init(sample:{sample},duration:{duration=$0;return true},logicalState:{commands.append(.init(duration:duration,state:$0));return true},keepKeyboardDark:{true},now:{now},frameInterval:frameInterval))
        copyState(to:next)
        try next.apply(level)
        return .init(owner:ObjectIdentifier(self),revision:revision,next:next,commands:commands)
    }
    func execute(_ plan: Plan) throws {
        guard plan.owner == ObjectIdentifier(self), plan.revision == revision else {
            throw RuntimeServices.failure("The planned logo frame is stale.")
        }
        revision &+= 1
        if plan.hasWrites {active=true}
        for command in plan.commands {try write(duration:command.duration,state:command.state)}
        plan.next.copyState(to:self)
    }
    private func copyState(to other: ClosedLidEffect) {
        other.active=active;other.direction=direction;other.moving=moving;other.holding=holding
        other.zeroRiseStartedAt=zeroRiseStartedAt;other.zeroBaselineStartedAt=zeroBaselineStartedAt
        other.pendingEndpoint=pendingEndpoint
    }

    func apply(_ level: Double) throws {
        revision &+= 1
        guard level.isFinite, let sample = io.sample(), sample.factor.isFinite,
              (0...1).contains(sample.factor), sample.appliedNits.isFinite,
              sample.multiplier.isFinite, sample.appliedNits >= 0, sample.multiplier >= 0, (sample.appliedNits * sample.multiplier).isFinite else {
            throw RuntimeServices.failure("Closed-lid light output is unavailable.")
        }
        let target = Effects.clamp(level)
        if pendingEndpoint?.target != target { pendingEndpoint = nil }
        if let pending = pendingEndpoint {
            let now = io.now()
            guard now.isFinite, now >= pending.startedAt, now - pending.startedAt < 3 else {
                throw RuntimeServices.failure("The requested logo endpoint was not confirmed. Logo control was stopped.")
            }
        }
        // Effects are normalized brightness, not an absolute photometric promise.
        // Retain macOS ambient limits; never divide by a low/zero baseline.
        // A temporarily gated output is valid: wait for the watchdog/hardware.
        guard sample.appliedNits > 0, sample.multiplier > 0 else {
            moving=false
            if zeroBaselineStartedAt == nil {zeroBaselineStartedAt=io.now()}
            guard io.now()-zeroBaselineStartedAt!<3 else {
                throw RuntimeServices.failure("The native logo brightness source is still unavailable. Logo control was stopped.")
            }
            return
        }
        zeroBaselineStartedAt=nil
        let difference = target - sample.factor
        if sample.factor > 0 || target == 0 { zeroRiseStartedAt = nil; zeroBaselineStartedAt = nil }
        // Mark ownership before writes so a partial failure is restored too.
        active = true
        let nearInterior = target > 0 && target < 1 && sample.factor > 0 && abs(difference) <= 0.012
        if target == 0 || target == 1 {
            if pendingEndpoint != nil {
                // Wait for an exact observed endpoint after the command. Never
                // keep restarting an eased fade near zero/one: it can approach
                // the endpoint forever without actually reaching it.
                if sample.factor == target {
                    pendingEndpoint = nil; moving = false; holding = false
                }
                return
            }
            let endpoint = target == 0 ? 1 : 2
            if sample.factor == target, direction == endpoint, !moving, !holding { return }
            let now = io.now()
            guard now.isFinite, now >= 0 else {
                throw RuntimeServices.failure("The logo endpoint deadline is unavailable.")
            }
            // CoreBrightness may ignore a repeated logical state. Prime only
            // when that state is already selected or its direction is unknown.
            if direction == nil || direction == endpoint {
                try write(duration: 5, state: endpoint == 2 ? 1 : 2)
            }
            try write(duration: 0, state: endpoint)
            direction = endpoint; moving = true; holding = false
            zeroRiseStartedAt = nil
            pendingEndpoint = .init(target: target, startedAt: now)
            return
        }
        if nearInterior {
            if !holding {
                // Always settle toward dark with a finite residual lifetime.
                // Continue sampling so drift is corrected; never leave a
                // billion-second native ramp behind after a crash/sleep.
                if direction == 1 || direction == nil {try write(duration:5,state:2)}
                try write(duration:5,state:1)
                direction=1;moving=false;holding=true
            }
            return
        }
        let next = difference > 0 ? 2 : 1
        if moving && direction == 2 && sample.factor == 0 && next == 2,
           let started = zeroRiseStartedAt {
            // A first rise waits for macOS's display-ready gate. Reissuing a
            // changing Breathe/Music target here can continually rearm it.
            guard io.now() - started < 3 else {
                throw RuntimeServices.failure("macOS has not enabled the closed-lid light output. Logo control was stopped.")
            }
            return
        }
        // Re-target a short eased step rather than let a full-range fade
        // overshoot a moving peak. A frame takes roughly 17 ms to begin;
        // budget the remaining frame interval for continuous native movement.
        if direction == nil || direction == next {
            try write(duration: 5, state: next == 2 ? 1 : 2)
        }
        let remaining = next == 2 ? 1 - sample.factor : sample.factor
        let fraction = min(0.98, abs(difference) / max(remaining, 0.0001))
        var lo = 0.0, hi = 1.0
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            let p = 1 - (1 + 6.51 * mid) * exp(-6.51 * mid)
            if p < fraction { lo = mid } else { hi = mid }
        }
        let calculated = max(0.04, min(5, max(0.005,io.frameInterval-0.015) / max(0.001, (lo + hi) / 2)))
        // The first hardware-ready frame can arrive between polls. Start that
        // rise gently so a low steady target does not briefly flash full scale.
        let duration = sample.factor == 0 && next == 2 ? max(0.5,calculated) : calculated
        try write(duration: duration, state: next)
        direction = next; moving = true; holding = false
        if sample.factor == 0 && next == 2 { zeroRiseStartedAt = io.now() }
    }
    private func write(duration: Double, state: Int) throws {
        let durationWritten = io.duration(duration)
        let stateWritten = durationWritten && io.logicalState(state)
        let keyboardSafe = io.keepKeyboardDark()
        guard durationWritten && stateWritten && keyboardSafe else {
            throw RuntimeServices.failure("Could not safely apply closed-lid lighting. Restore Light before retrying.")
        }
    }
    func restore() throws {
        revision &+= 1
        guard active else { return }
        try write(duration: 5, state: 1)
        try write(duration: 0, state: 2)
        active = false; direction = nil; moving = false; holding = false; zeroRiseStartedAt = nil; pendingEndpoint = nil
    }

    static func liveInterface(client existingClient: NSObject? = nil) -> Interface? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL) != nil,
              let kind = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              let keyboardKind = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = existingClient ?? kind.init(), keyboard = keyboardKind.init()
        let reader = NSSelectorFromString("copyPropertyForKey:"), writer = NSSelectorFromString("setProperty:forKey:")
        let keyboardWriter = NSSelectorFromString("setProperty:withKey:keyboardID:")
        let idsReader = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard client.responds(to: reader), client.responds(to: writer), client.responds(to: keyboardWriter), keyboard.responds(to: idsReader),
              let ids = keyboard.perform(idsReader)?.takeRetainedValue() as? [NSNumber], !ids.isEmpty else { return nil }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
        typealias KeyboardSetter = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool
        func set(_ key: String, _ value: NSNumber) -> Bool {
            unsafeBitCast(client.method(for: writer), to: Setter.self)(client, writer, value, key as NSString)
        }
        return Interface(sample: {
            guard let state = client.perform(reader, with: "LEPWMState")?.takeRetainedValue() as? [String: NSNumber],
                  let factor = state["Factor"], let nits = state["AppliedNits"], let multiplier = state["NitsMultiplier"] else { return nil }
            return Sample(factor: factor.doubleValue, appliedNits: nits.doubleValue, multiplier: multiplier.doubleValue)
        }, duration: { set("LEPWMFactorFadeDuration", NSNumber(value: $0)) }, logicalState: { set("DisplayLogicalState", NSNumber(value: $0)) }, keepKeyboardDark: {
            // On a real reopen leave keyboard policy to macOS. Never fake the
            // physical lid state here; that belongs to the safety watchdog.
            guard let closed = RuntimeServices.physicalLidClosed else { return false }
            if !closed { return true }
            var safe = true
            for id in ids {
                let restored = unsafeBitCast(client.method(for: keyboardWriter), to: KeyboardSetter.self)(client, keyboardWriter, NSNumber(value: true), "ClamshellUpdate", id.uint64Value)
                safe = restored && safe
            }
            return safe
        })
    }
}
