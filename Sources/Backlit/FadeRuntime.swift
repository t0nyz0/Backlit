import Foundation
import Darwin

struct FadeProcessIdentity: Codable, Equatable {
    let pid: Int32
    let seconds: UInt64
    let microseconds: UInt64
    static func read(_ pid: Int32) -> Self? {
        guard pid>0 else{return nil}
        var info=proc_bsdinfo()
        guard proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else{return nil}
        return .init(pid:pid,seconds:info.pbi_start_tvsec,microseconds:info.pbi_start_tvusec)
    }
    var isAlive: Bool { Self.read(pid)==self }
}

struct FadeHelperArguments {
    let token:UUID
    let parent:FadeProcessIdentity
    init?(_ arguments:[String]) {
        guard let i=arguments.firstIndex(of:"--watch-fade"),arguments.count==i+5,
              let token=UUID(uuidString:arguments[i+1]),let pid=Int32(arguments[i+2]),pid>0,
              let seconds=UInt64(arguments[i+3]),seconds>0,let microseconds=UInt64(arguments[i+4]),microseconds<1_000_000 else{return nil}
        self.token=token;parent = .init(pid:pid,seconds:seconds,microseconds:microseconds)
    }
}

/// Unified fade lifecycle. Merely compiling this adapter performs no hardware
/// writes. A separate helper is ready before the first owned effect batch.
final class FadeRuntime: FadeEffectSession {
    private let hardware:LiveFadeHardware
    private let store:FadeRecoveryStore
    private let token:UUID
    private let leaseURL:URL
    private let child:Process
    private let childIdentity:FadeProcessIdentity
    private let started=ProcessInfo.processInfo.systemUptime
    private let independentSource: IndependentLogoSource?
    private var effect:ClosedLidEffect
    private var requestedClosed=false
    private var hadWriteFailure=false
    var ownsIndependentSource: Bool { independentSource != nil }
    var needsAnimation:Bool { independentSource?.installed == false || effect.needsAnimation || (try? store.read().effectsAllowed) != true }

    init(closedLidRequested:Bool, expectedMapping: [[Double]]? = nil) throws {
        hardware=try LiveFadeHardware.makeLive()
        guard let context=hardware.currentContext(),let keyboards=hardware.keyboardStates(),
              let parent=FadeProcessIdentity.read(getpid()),let io=ClosedLidEffect.liveInterface() else {
            throw RuntimeServices.failure("Safe logo fade control is unavailable.")
        }
        if context.permitsOpenKeyboardRestore {
            guard let original = hardware.currentMapping(), LogoDevice.valid(original),
                  expectedMapping.map({ LogoDevice.equivalent(original, $0) }) ?? true else {
                throw RuntimeServices.failure("The original logo source changed before ownership was established.")
            }
            independentSource = IndependentLogoSource(original: original)
        } else { independentSource = nil }
        store=FadeRecoveryStore(directory:AgentBridge.directory)
        token=try store.prepare(parentPID:parent.pid,context:context,keyboards:keyboards,closedLidRequested:closedLidRequested, logoSource:independentSource?.recovery)
        requestedClosed=closedLidRequested
        leaseURL=AgentBridge.directory.appendingPathComponent("fade-lease-\(token.uuidString)")
        // Every execution and healthy restore below is enclosed by the full
        // keyboard guard. Avoid duplicate per-command closed notifications;
        // standalone/diagnostic interfaces retain their own safe callback.
        var guardedIO=io
        guardedIO.keepKeyboardDark={true}
        effect=ClosedLidEffect(interface:guardedIO)
        let process=Process();child=process
        process.executableURL=Bundle.main.executableURL
        process.arguments=["--watch-fade",token.uuidString,String(parent.pid),String(parent.seconds),String(parent.microseconds)]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        do {
            try Data().write(to:leaseURL,options:.atomic)
            try process.run()
            guard let identity=FadeProcessIdentity.read(process.processIdentifier) else {
                throw RuntimeServices.failure("Could not verify the fade recovery helper.")
            }
            childIdentity=identity
        } catch {
            // No fade has been written. Removing its lease lets any helper that
            // did start perform cleanup; never force-kill a recovery process.
            try? FileManager.default.removeItem(at:leaseURL)
            throw error
        }
    }

    /// A receipt is useful only for this exact token. Never reinterpret a new
    /// owner's journal (or an unreadable one) as permission to restart.
    static func interrupted(record: FadeRecoveryRecord?, completed: Bool, token: UUID, helperAlive: Bool) -> Bool {
        if let record {
            guard record.token == token else { return false }
            return !helperAlive || (record.watchdogPID != nil && !record.effectsAllowed)
        }
        return completed
    }

    static func safetyTransitionInterrupted(record: FadeRecoveryRecord?, token: UUID,
                                           before: FadeSafetyContext?, after: FadeSafetyContext?) -> Bool {
        guard let record, record.token == token, let before, let after else { return false }
        return before != after
    }

    enum FrameEntry: Equatable { case proceed, paused, switchSource }

    /// Ordinary pause policy is decided first, so a session created during
    /// sleep or lock pauses instead of being treated as a failed session.
    /// Never carry an independent open-lid source into the closed path, or a
    /// closed-only session into the open path: retirement must restore the
    /// old session before a replacement of the other kind can start.
    static func frameEntry(context: FadeSafetyContext, ownsIndependentSource: Bool, closedLidRequested: Bool) -> FrameEntry {
        if context.sleeping || context.locked || (context.lidClosed && !closedLidRequested) { return .paused }
        return ownsIndependentSource == context.lidClosed ? .switchSource : .proceed
    }

    func apply(_ brightness:Double, closedLidRequested:Bool, frameInterval:Double = 0.05) throws -> FadeApplyResult {
        let before = hardware.currentContext()
        do { return try applyFrame(brightness, closedLidRequested: closedLidRequested, frameInterval: frameInterval) }
        catch FadeSessionInterruption.sourceMode {
            // An expected lid transition, decided before any journal or
            // hardware access. Keep it distinct from a lifecycle fault.
            throw FadeSessionInterruption.sourceMode
        }
        catch {
            let record = try? store.read()
            // The keyboard guard can detect a completed power/session change
            // before the watchdog has revoked the still-owned journal.
            if Self.safetyTransitionInterrupted(record: record, token: token, before: before, after: hardware.currentContext()) {
                throw FadeSessionInterruption.lifecycle
            }
            if Self.interrupted(record: record, completed: store.completed(token: token), token: token, helperAlive: childIdentity.isAlive),
               record != nil || !FileManager.default.fileExists(atPath: store.url.path) {
                throw FadeSessionInterruption.lifecycle
            }
            throw error
        }
    }

    private func applyFrame(_ brightness:Double, closedLidRequested:Bool, frameInterval:Double) throws -> FadeApplyResult {
        guard let initialContext=hardware.currentContext() else {throw RuntimeServices.failure("Logo safety state is unavailable.")}
        switch Self.frameEntry(context: initialContext, ownsIndependentSource: independentSource != nil, closedLidRequested: closedLidRequested) {
        case .paused: return .paused
        case .switchSource: throw FadeSessionInterruption.sourceMode
        case .proceed: break
        }
        guard childIdentity.isAlive else {throw RuntimeServices.failure("The fade recovery helper stopped; logo control was paused.")}
        let record=try store.read()
        guard record.token==token else {throw RuntimeServices.failure("Logo fade ownership changed.")}
        guard record.effectsAllowed else {
            if record.watchdogPID != nil {throw RuntimeServices.failure("Fade recovery is in progress. Logo control was paused.")}
            guard ProcessInfo.processInfo.systemUptime-started<3 else {throw RuntimeServices.failure("The fade recovery helper did not become ready.")}
            return .waiting
        }
        if requestedClosed != closedLidRequested {
            try store.setClosedLidRequested(token:token,value:closedLidRequested)
            requestedClosed=closedLidRequested
        }
        guard let context=hardware.currentContext() else {
            throw RuntimeServices.failure("Logo or keyboard safety state is unavailable.")
        }
        if context.lidClosed {
            guard closedLidRequested else {return .paused}
            // The existing lid helper alone owns the global lid override and its
            // battery/thermal/time limits. Never animate before it grants access.
            guard ClosedEffectSession.permitted() else{return .waiting}
        }
        return try Self.applyPermittedFrame(brightness, closedLidRequested: closedLidRequested,
            frameInterval: frameInterval, effect: effect, hardware: hardware, store: store, token: token,
            watchdogPID: childIdentity.pid, watchdogAlive: { self.childIdentity.isAlive },
            lidPermission: { ClosedEffectSession.permitted() }, source: independentSource, markWriteFailure: { self.hadWriteFailure = true })
    }

    /// Production permission/planning/write path shared with inert fixtures.
    /// Readiness follows the plan outcome, including successful no-write waits.
    static func applyPermittedFrame(_ brightness: Double, closedLidRequested: Bool, frameInterval: Double,
                                   effect: ClosedLidEffect, hardware: LiveFadeHardware,
                                   store: FadeRecoveryStore, token: UUID, watchdogPID: Int32,
                                   watchdogAlive: () -> Bool, lidPermission: () -> Bool,
                                   source: IndependentLogoSource? = nil, markWriteFailure: () -> Void) throws -> FadeApplyResult {
        var result=FadeApplyResult.waiting
        var plan:ClosedLidEffect.Plan?
        var planContext:FadeSafetyContext?
        var sourcePlan: LogoSourceRecovery?
        _ = try store.withPermission(token:token,watchdogAlive:{ $0==watchdogPID && watchdogAlive() },snapshotProvider:{
            guard let context=hardware.currentContext() else {
                throw RuntimeServices.failure("Logo safety state is unavailable before the frame.")
            }
            guard context==planContext else { throw FadeSessionInterruption.lifecycle }
            guard let keyboards=hardware.keyboardStates() else {
                throw RuntimeServices.failure("Keyboard state is unavailable before the logo frame.")
            }
            return .init(context:context,keyboardStates:keyboards)
        },shouldWrite:{
            guard let fresh=hardware.currentContext(),Self.frameAllowed(context:fresh,closedRequested:closedLidRequested,lidPermission:lidPermission()) else {return false}
            planContext=fresh
            if let source {
                guard fresh.permitsOpenKeyboardRestore else { throw FadeSessionInterruption.lifecycle }
                sourcePlan = try source.plan(brightness, current: hardware.currentMapping())
                if sourcePlan != nil { return true }
            }
            let target = source == nil ? brightness : (brightness > 0 ? 1.0 : 0.0)
            let next=try effect.plan(target,frameInterval:frameInterval)
            if !next.hasWrites {try effect.execute(next);result = next.result;return false}
            plan=next;return true
        }, sourceUpdate: { sourcePlan }) {
            guard plan != nil || sourcePlan != nil else {return}
            do {
                try hardware.guardedFadeWrite {
                    guard let current = hardware.currentContext() else {
                        throw RuntimeServices.failure("Logo safety state is unavailable before the frame.")
                    }
                    guard current==planContext,
                          Self.frameAllowed(context:current,closedRequested:closedLidRequested,lidPermission:lidPermission()) else {
                        throw FadeSessionInterruption.lifecycle
                    }
                    if let sourcePlan, let source {
                        try hardware.installSource(source, plan: sourcePlan, context: current)
                        // Never use the pre-mapping sample for the effect plan.
                        guard hardware.currentContext() == current else { throw FadeSessionInterruption.lifecycle }
                        let freshPlan = try effect.plan(brightness > 0 ? 1 : 0, frameInterval: frameInterval)
                        try effect.execute(freshPlan)
                        result = freshPlan.result
                    } else if let plan {
                        try effect.execute(plan)
                        result = plan.result
                    }
                }
            } catch {markWriteFailure();throw error}
        }
        return result
    }

    func restore() throws {
        if FileManager.default.fileExists(atPath:store.url.path) || store.completed(token:token) {
            try store.recover(token:token) { record in
                try Self.restore(record, hardware: hardware, effect: effect, hadWriteFailure: hadWriteFailure) {
                    self.hadWriteFailure = true
                }
            }
        } else {
            throw RuntimeServices.failure("Fade recovery completion could not be verified. Recovery is still required.")
        }
        effect.relinquish()
        if FileManager.default.fileExists(atPath:leaseURL.path) {try FileManager.default.removeItem(at:leaseURL)}
    }

    /// Shared with inert fixtures so retry routing is tested with the actual
    /// effect, hardware adapter and durable recovery store.
    static func restore(_ record: FadeRecoveryRecord, hardware: LiveFadeHardware,
                        effect: ClosedLidEffect, hadWriteFailure: Bool,
                        markWriteFailure: () -> Void) throws {
        guard record.pendingBatch != nil else {return}
        if !hadWriteFailure, hardware.currentContext()?.permitsOpenKeyboardRestore == true {
            do {
                // A healthy, still-running owner can preserve a fresh
                // keyboard snapshot during normal open-lid shutdown.
                try hardware.restoreSource(record)
                try hardware.guardedFadeWrite {try effect.restore()}
                try hardware.confirmTerminal()
            } catch {
                // The effect can be inactive after the setters returned true while
                // terminal confirmation or keyboard restoration still fails.
                // Retry the conservative reset, not that inactive no-op.
                markWriteFailure()
                throw error
            }
        } else {
            try hardware.restore(record)
        }
    }

    static func frameAllowed(context:FadeSafetyContext,closedRequested:Bool,lidPermission:Bool) -> Bool {
        !context.sleeping && !context.locked && (!context.lidClosed || (closedRequested && lidPermission))
    }

    static func recoverPending() throws {
        let store=FadeRecoveryStore(directory:AgentBridge.directory)
        guard FileManager.default.fileExists(atPath:store.url.path) else{return}
        let record=try store.read()
        if record.pendingBatch == nil {
            // Failed startup cannot require unavailable hardware to clear a
            // journal that provably preceded every possible fade write.
            try store.recover(token:record.token) { _ in }
        } else {
            let hardware=try LiveFadeHardware.makeLive()
            try store.recover(token:record.token) { try hardware.restore($0) }
        }
        let lease=AgentBridge.directory.appendingPathComponent("fade-lease-\(record.token.uuidString)")
        if FileManager.default.fileExists(atPath:lease.path){try FileManager.default.removeItem(at:lease)}
    }

    static func runHelper(_ request:FadeHelperArguments) -> Int32 {
        let store=FadeRecoveryStore(directory:AgentBridge.directory)
        guard let record=try? store.read(),record.token==request.token,record.parentPID==request.parent.pid,
              request.parent.isAlive,let hardware=try? LiveFadeHardware.makeLive() else{return 2}
        let lease=AgentBridge.directory.appendingPathComponent("fade-lease-\(request.token.uuidString)")
        var awaitingGateSince:Double?
        return FadeRecoveryWatchdog(store:store,token:request.token).run(watchdogPID:getpid(),parentAlive:{ $0==request.parent.pid && request.parent.isAlive },leasePresent:{
            guard FileManager.default.fileExists(atPath:lease.path),let context=hardware.currentContext(),!context.sleeping,!context.locked else{return false}
            guard context.lidClosed else {awaitingGateSince=nil;return true}
            guard let current=try? store.read() else{return false}
            guard current.closedLidRequested==true else{return current.pendingBatch==nil}
            let power=RuntimeServices.battery()
            guard LidSessionPolicy.eligible(exhausted:false,externalPower:power.1,battery:power.0,lowPower:ProcessInfo.processInfo.isLowPowerModeEnabled,thermal:ProcessInfo.processInfo.thermalState) else{return false}
            if ClosedEffectSession.permitted(){awaitingGateSince=nil;return true}
            let now=ProcessInfo.processInfo.systemUptime
            if awaitingGateSince==nil {awaitingGateSince=now}
            return now-awaitingGateSince!<3
        },wait:{hardware.waitForSafetyEvent(0.25)},retryWait:{hardware.waitForSafetyEvent($0)},reportFailure:{ error in
            FileHandle.standardError.write(Data(("Fade recovery pending: "+error.localizedDescription+"\n").utf8))
        },restore:{try hardware.restore($0)})
    }
}
