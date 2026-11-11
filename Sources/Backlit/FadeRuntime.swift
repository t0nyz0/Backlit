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
    private var effect:ClosedLidEffect
    private var requestedClosed=false
    private var hadWriteFailure=false
    var needsAnimation:Bool { effect.needsAnimation || (try? store.read().effectsAllowed) != true }

    init(closedLidRequested:Bool) throws {
        hardware=try LiveFadeHardware.makeLive()
        guard let context=hardware.currentContext(),let keyboards=hardware.keyboardStates(),
              let parent=FadeProcessIdentity.read(getpid()),let io=ClosedLidEffect.liveInterface() else {
            throw RuntimeServices.failure("Safe logo fade control is unavailable.")
        }
        store=FadeRecoveryStore(directory:AgentBridge.directory)
        token=try store.prepare(parentPID:parent.pid,context:context,keyboards:keyboards,closedLidRequested:closedLidRequested)
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

    func apply(_ brightness:Double, closedLidRequested:Bool, frameInterval:Double = 0.05) throws -> FadeApplyResult {
        guard let initialContext=hardware.currentContext() else {throw RuntimeServices.failure("Logo safety state is unavailable.")}
        if initialContext.lidClosed && !closedLidRequested {return .paused}
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
        var result=FadeApplyResult.waiting
        var plan:ClosedLidEffect.Plan?
        var planContext:FadeSafetyContext?
        _ = try store.withPermission(token:token,watchdogAlive:{ $0==self.childIdentity.pid && self.childIdentity.isAlive },snapshotProvider:{
            guard let context=hardware.currentContext(), context==planContext,
                  let keyboards=hardware.keyboardStates() else {
                throw RuntimeServices.failure("Safety state changed before the logo frame.")
            }
            return .init(context:context,keyboardStates:keyboards)
        },shouldWrite:{
            guard let fresh=hardware.currentContext(),Self.frameAllowed(context:fresh,closedRequested:closedLidRequested,lidPermission:ClosedEffectSession.permitted()) else {return false}
            planContext=fresh
            let next=try effect.plan(brightness,frameInterval:frameInterval)
            if !next.hasWrites {try effect.execute(next);result = .applied;return false}
            plan=next;return true
        }) {
            guard let plan else {return}
            do {
                try hardware.guardedFadeWrite {
                    guard hardware.currentContext()==planContext,
                          Self.frameAllowed(context:planContext!,closedRequested:closedLidRequested,lidPermission:ClosedEffectSession.permitted()) else {
                        throw RuntimeServices.failure("Safety state changed before the logo frame.")
                    }
                    try effect.execute(plan)
                    result = .applied
                }
            } catch {hadWriteFailure=true;throw error}
        }
        return result
    }

    func restore() throws {
        if FileManager.default.fileExists(atPath:store.url.path) || store.completed(token:token) {
            try store.recover(token:token) { record in
                guard record.pendingBatch != nil else {return}
                if !hadWriteFailure, hardware.currentContext()?.permitsOpenKeyboardRestore == true {
                    // A healthy, still-running owner can preserve a fresh
                    // keyboard snapshot during normal open-lid shutdown.
                    try hardware.guardedFadeWrite {try effect.restore()}
                    try hardware.confirmTerminal()
                } else {
                    try hardware.restore(record)
                }
            }
        } else {
            throw RuntimeServices.failure("Fade recovery completion could not be verified. Recovery is still required.")
        }
        effect.relinquish()
        if FileManager.default.fileExists(atPath:leaseURL.path) {try FileManager.default.removeItem(at:leaseURL)}
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
