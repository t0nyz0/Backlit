import Foundation

/// Experimental safety primitives for a future unified fade path. Not wired to
/// live controls until crash recovery and physical keyboard QA are complete.
struct FadeSafetyContext: Codable, Equatable {
    let lidClosed: Bool
    let sleeping: Bool
    let locked: Bool
    /// Monotonic generation from lid/display/session notifications. A transition
    /// away and back must still invalidate a previously captured keyboard state.
    let generation: UInt64
    var permitsOpenKeyboardRestore: Bool { !lidClosed && !sleeping && !locked }
}

final class FadeKeyboardGuard {
    struct Interface {
        var context: () -> FadeSafetyContext?
        var keyboardStates: () -> [UInt64: Int]?
        var setLogicalState: (UInt64, Int) -> Bool
        var setClosed: (UInt64) -> Bool
    }
    private let io: Interface
    init(interface: Interface) { io = interface }

    func perform(_ fadeWrite: () throws -> Void) throws {
        guard let before=io.context(), !before.sleeping, !before.locked,
              let saved=io.keyboardStates(), !saved.isEmpty,
              saved.values.allSatisfy({ (0...6).contains($0) }), io.context() == before else {
            throw RuntimeServices.failure("Keyboard state changed before logo control could be applied.")
        }
        var writeError: Error?
        do { try fadeWrite() } catch { writeError=error }
        // Restore independently even after a partial fade failure. Never replay
        // Unblank from an earlier safety generation.
        let observed=io.keyboardStates()
        let currentIDs=observed.map { Array($0.keys) } ?? []
        var restored=observed != nil && Set(saved.keys) == Set(currentIDs)
        let ids=Set(saved.keys).union(currentIDs)
        for id in ids.sorted() {
            guard let current=io.context() else { restored=false; continue }
            if current.lidClosed {
                restored = io.setClosed(id) && restored
            } else if observed == nil || !current.permitsOpenKeyboardRestore || current != before || saved[id] == nil {
                // Unknown/new keyboard or intervening sleep: fail dark rather
                // than replay a stale wake instruction.
                restored = io.setLogicalState(id,1) && restored
            } else {
                restored = io.setLogicalState(id,saved[id]!) && restored
            }
        }
        // A transition during restoration invalidates success. The owner must
        // stop effects and let its independent recovery process reconcile it.
        guard restored, io.context() == before else {
            throw RuntimeServices.failure("Keyboard or power state changed; fade recovery is required.")
        }
        if let writeError { throw writeError }
    }
}

struct FadeBatchSnapshot: Codable, Equatable {
    let context: FadeSafetyContext
    let keyboardStates: [UInt64:Int]
}

struct FadeRecoveryRecord: Codable, Equatable {
    let token: UUID
    let parentPID: Int32
    let originalContext: FadeSafetyContext
    let keyboardStates: [UInt64: Int]
    var watchdogPID: Int32?
    var effectsAllowed: Bool
    var pendingBatch: FadeBatchSnapshot?
    var closedLidRequested: Bool?
    var logoSource: LogoSourceRecovery? = nil
}

/// Durable ownership is separate from the closed-lid lease: open-lid fades must
/// also survive the app crashing. All clients use the existing effect lock.
final class FadeRecoveryStore {
    let directory: URL
    var url: URL { directory.appendingPathComponent("fade-recovery.json") }
    private struct Completion: Codable { let token: UUID; let unusedSession: Bool }
    private var completionURL: URL {directory.appendingPathComponent("fade-completed.json")}
    private let receiptWriter: (Data,URL) throws -> Void
    private let journalRemover: (URL) throws -> Void
    init(directory: URL, receiptWriter: @escaping (Data,URL)throws->Void = {try $0.write(to:$1,options:.atomic)},
         journalRemover: @escaping (URL)throws->Void = {try FileManager.default.removeItem(at:$0)}) {
        self.directory=directory;self.receiptWriter=receiptWriter;self.journalRemover=journalRemover
    }
    func completed(token: UUID) -> Bool {
        guard let data=try? Data(contentsOf:completionURL),let receipt=try? JSONDecoder().decode(Completion.self,from:data) else {return false}
        return receipt.token==token
    }
    func read() throws -> FadeRecoveryRecord {
        try JSONDecoder().decode(FadeRecoveryRecord.self,from:Data(contentsOf:url))
    }
    private func write(_ record: FadeRecoveryRecord) throws {
        try JSONEncoder().encode(record).write(to:url,options:.atomic)
    }
    func prepare(parentPID: Int32, context: FadeSafetyContext, keyboards: [UInt64:Int], closedLidRequested: Bool = false, logoSource: LogoSourceRecovery? = nil) throws -> UUID {
        guard logoSource?.valid ?? true, parentPID>0,!keyboards.isEmpty,keyboards.values.allSatisfy({(0...6).contains($0)}) else {
            throw RuntimeServices.failure("Cannot prepare fade recovery without a valid owner and keyboard state.")
        }
        return try ClosedEffectSession.locked(directory:directory,wait:true) {
            guard !FileManager.default.fileExists(atPath:self.url.path) else {
                throw RuntimeServices.failure("Previous fade recovery must finish before starting another session.")
            }
            let token=UUID()
            try self.write(.init(token:token,parentPID:parentPID,originalContext:context,keyboardStates:keyboards,watchdogPID:nil,effectsAllowed:false,pendingBatch:nil,closedLidRequested:closedLidRequested,logoSource:logoSource))
            return token
        }!
    }
    func acknowledgeWatchdog(token: UUID, watchdogPID: Int32, parentAlive: (Int32)->Bool) throws {
        _ = try ClosedEffectSession.locked(directory:directory,wait:true) {
            var record=try self.read()
            guard record.token==token,record.watchdogPID==nil,watchdogPID>0,parentAlive(record.parentPID) else {
                throw RuntimeServices.failure("Fade watchdog could not claim this session.")
            }
            record.watchdogPID=watchdogPID;record.effectsAllowed=true
            try self.write(record)
        }
    }
    func setClosedLidRequested(token:UUID,value:Bool) throws {
        _ = try ClosedEffectSession.locked(directory:directory,wait:true) {
            var record=try self.read()
            guard record.token==token,record.effectsAllowed else {throw RuntimeServices.failure("Fade session is not ready.")}
            if record.closedLidRequested != value {record.closedLidRequested=value;try self.write(record)}
        }
    }
    func withPermission<T>(token: UUID, watchdogAlive: (Int32)->Bool, snapshot: FadeBatchSnapshot, _ body: () throws -> T) throws -> T? {
        try withPermission(token:token,watchdogAlive:watchdogAlive,snapshotProvider:{snapshot},body)
    }
    func withPermission<T>(token: UUID, watchdogAlive: (Int32)->Bool,
                           snapshotProvider: () throws -> FadeBatchSnapshot,
                           shouldWrite: () throws -> Bool = {true},
                           sourceUpdate: () -> LogoSourceRecovery? = {nil},
                           _ body: () throws -> T) throws -> T? {
        let result: T?? = try ClosedEffectSession.locked(directory:directory,wait:false) { () throws -> T? in
            var record=try self.read()
            guard record.token==token,record.effectsAllowed,let pid=record.watchdogPID,watchdogAlive(pid) else {
                throw RuntimeServices.failure("Fade watchdog is not ready; no light changes were made.")
            }
            guard try shouldWrite() else {return nil}
            let snapshot=try snapshotProvider()
            guard !snapshot.keyboardStates.isEmpty, snapshot.keyboardStates.values.allSatisfy({(0...6).contains($0)}),
                  !snapshot.context.sleeping, !snapshot.context.locked else {
                throw RuntimeServices.failure("Cannot write a fade without a current safe keyboard snapshot.")
            }
            // Identical safety snapshots remain valid across frames. Persist
            // changes, not two disk writes per animation tick; keep the latest
            // snapshot even after success for independent crash restoration.
            let source = sourceUpdate()
            if let source {
                guard source.valid, let prior = record.logoSource,
                      LogoDevice.equivalent(source.original, prior.original) else {
                    throw RuntimeServices.failure("The independent logo recovery source is invalid.")
                }
            }
            if record.pendingBatch != snapshot || (source != nil && record.logoSource != source) {
                record.pendingBatch=snapshot
                if let source { record.logoSource = source }
                try self.write(record)
            }
            return try body()
        }
        return result ?? nil
    }
    /// The watchdog revokes under the very lock used by effect batches, then
    /// restores. Failed cleanup retains a revoked record for explicit recovery.
    func recover(token: UUID, restore: (FadeRecoveryRecord) throws -> Void) throws {
        _ = try ClosedEffectSession.locked(directory:directory,wait:true) {
            let current:FadeRecoveryRecord
            do {current=try self.read()}
            catch {
                let error=error as NSError
                let missing=(error.domain==NSCocoaErrorDomain && [NSFileNoSuchFileError,NSFileReadNoSuchFileError].contains(error.code)) || (error.domain==NSPOSIXErrorDomain && error.code==Int(ENOENT))
                guard missing,self.completed(token:token) else {throw error}
                return // Another verified owner completed this exact session.
            }
            var record=current
            guard record.token==token else {throw RuntimeServices.failure("Fade recovery owner changed.")}
            if self.completed(token:token), !record.effectsAllowed {
                try self.journalRemover(self.url);return
            }
            record.effectsAllowed=false;try self.write(record)
            try restore(record)
            guard try self.read().token==token else {throw RuntimeServices.failure("Fade recovery owner changed during cleanup.")}
            // A receipt is proof of verified cleanup (or an explicitly unused
            // session), never merely proof that the helper process exited.
            let completion=Completion(token:token,unusedSession:record.pendingBatch==nil)
            try self.receiptWriter(JSONEncoder().encode(completion),self.completionURL)
            try self.journalRemover(self.url)
        }
    }
}

/// Independent process lifecycle with injected liveness and lease checks.
/// FadeRuntime supplies the live adapter; tests exercise parent crash, lease
/// removal, lock contention and failed restoration without hardware writes.
final class FadeRecoveryWatchdog {
    enum Result { case waiting, restored }
    let store: FadeRecoveryStore
    let token: UUID
    init(store: FadeRecoveryStore, token: UUID) { self.store=store;self.token=token }
    /// Entry point for an independently launched helper. Its acknowledgement is
    /// durable before the app can obtain permission for its first fade write.
    func run(watchdogPID: Int32, parentAlive: (Int32)->Bool, leasePresent: ()->Bool,
             wait: ()->Void, retryWait: (Double)->Void = { Thread.sleep(forTimeInterval:$0) },
             reportFailure: (Error)->Void = { _ in }, restore: (FadeRecoveryRecord)throws->Void) -> Int32 {
        do { try store.acknowledgeWatchdog(token:token,watchdogPID:watchdogPID,parentAlive:parentAlive) }
        catch { return 2 }
        var failures=0
        while true {
            do {
                if try poll(parentAlive:parentAlive,leasePresent:leasePresent,restore:restore) == .restored { return 0 }
                failures=0;wait()
            } catch {
                // Another owner or completed manual recovery must not be touched.
                if !FileManager.default.fileExists(atPath:store.url.path) { return 0 }
                if let current=try? store.read(), current.token != token { return 3 }
                failures += 1
                if failures == 1 { reportFailure(error) }
                // Do not abandon active hardware after a transient busy lock or
                // rejected restore. Remain independently alive, retrying slowly.
                retryWait(min(30,pow(2,Double(min(failures-1,5)))*0.25))
            }
        }
    }
    func poll(parentAlive: (Int32)->Bool, leasePresent: ()->Bool,
              restore: (FadeRecoveryRecord)throws->Void) throws -> Result {
        let record=try store.read()
        guard record.token==token else {throw RuntimeServices.failure("Fade watchdog ownership changed.")}
        if parentAlive(record.parentPID) && leasePresent() && record.effectsAllowed { return .waiting }
        try store.recover(token:token,restore:restore)
        return .restored
    }
}
