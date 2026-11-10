import XCTest
@testable import Backlit

final class FadeSessionSafetyTests: XCTestCase {
    let open=FadeSafetyContext(lidClosed:false,sleeping:false,locked:false,generation:1)
    func store() throws -> FadeRecoveryStore {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        addTeardownBlock {try? FileManager.default.removeItem(at:dir)}
        return FadeRecoveryStore(directory:dir)
    }
    func prepared(_ s:FadeRecoveryStore) throws -> UUID {
        try s.prepare(parentPID:123,context:open,keyboards:[13:2])
    }
    func testClosedPolicyIsPersistedBeforeChildCanAcknowledge() throws {
        let s=try store()
        let closed=FadeSafetyContext(lidClosed:true,sleeping:false,locked:false,generation:1)
        let t=try s.prepare(parentPID:123,context:closed,keyboards:[13:1],closedLidRequested:true)
        XCTAssertEqual(try s.read().closedLidRequested,true)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        XCTAssertEqual(try s.read().closedLidRequested,true)
    }
    func testLidRevocationBetweenPrecheckAndLockedFramePreventsWrite() throws {
        let s=try store(),t=try prepared(s)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        let closed=FadeSafetyContext(lidClosed:true,sleeping:false,locked:false,generation:2)
        var permitted=true, wrote=false
        XCTAssertTrue(FadeRuntime.frameAllowed(context:closed,closedRequested:true,lidPermission:permitted))
        // The lid helper has completed cleanup before the fade writer gets its lock.
        permitted=false
        _ = try s.withPermission(token:t,watchdogAlive:{_ in true},snapshot:.init(context:closed,keyboardStates:[13:1])) {
            guard FadeRuntime.frameAllowed(context:closed,closedRequested:true,lidPermission:permitted) else{return}
            wrote=true
        }
        XCTAssertFalse(wrote)
    }
    func testNoWritesBeforeIndependentWatchdogAcknowledgement() throws {
        let s=try store(),t=try prepared(s);var wrote=false
        XCTAssertThrowsError(try s.withPermission(token:t,watchdogAlive:{_ in true},snapshot:.init(context:open,keyboardStates:[13:2])) {wrote=true})
        XCTAssertFalse(wrote);XCTAssertFalse(try s.read().effectsAllowed)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{$0==123})
        _ = try s.withPermission(token:t,watchdogAlive:{$0==456},snapshot:.init(context:open,keyboardStates:[13:2])) {wrote=true}
        XCTAssertTrue(wrote)
    }
    func testDeadWatchdogAndWrongTokenNeverWrite() throws {
        let s=try store(),t=try prepared(s)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        for wrong in [false,true] {
            XCTAssertThrowsError(try s.withPermission(token:wrong ? UUID():t,watchdogAlive:{_ in wrong},snapshot:.init(context:open,keyboardStates:[13:2])) {XCTFail("Unauthorized frame")})
        }
    }
    func testCannotOverwritePriorCrashRecord() throws {
        let s=try store(),t=try prepared(s)
        XCTAssertThrowsError(try prepared(s));XCTAssertEqual(try s.read().token,t)
    }
    func testParentDeathRestoresAfterRevocation() throws {
        let s=try store(),t=try prepared(s)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        let watchdog=FadeRecoveryWatchdog(store:s,token:t)
        XCTAssertEqual(try watchdog.poll(parentAlive:{_ in true},leasePresent:{true},restore:{_ in XCTFail("Premature restore")}),.waiting)
        XCTAssertEqual(try watchdog.poll(parentAlive:{_ in false},leasePresent:{true},restore:{record in
            XCTAssertFalse(record.effectsAllowed);XCTAssertFalse(try s.read().effectsAllowed)
        }),.restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.url.path))
    }
    func testLeaseRemovalRestoresEvenIfParentStillAlive() throws {
        let s=try store(),t=try prepared(s)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        XCTAssertEqual(try FadeRecoveryWatchdog(store:s,token:t).poll(parentAlive:{_ in true},leasePresent:{false},restore:{_ in}),.restored)
    }
    func testFailedRestorationPersistsRevokedRecoveryAcrossRelaunch() throws {
        let s=try store(),t=try prepared(s)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        XCTAssertThrowsError(try s.recover(token:t) {_ in throw NSError(domain:"test",code:1)})
        let relaunched=FadeRecoveryStore(directory:s.directory)
        XCTAssertEqual(try relaunched.read().token,t);XCTAssertFalse(try relaunched.read().effectsAllowed)
        try relaunched.recover(token:t) {_ in}
        XCTAssertFalse(FileManager.default.fileExists(atPath:s.url.path))
    }
    func testKeyboardLogicalStatesPreservedWithoutBrightnessWrites() throws {
        for state in 0...6 {
            var writes:[Int]=[]
            let guarder=FadeKeyboardGuard(interface:.init(context:{self.open},keyboardStates:{[13:state]},setLogicalState:{_,v in writes.append(v);return true},setClosed:{_ in XCTFail("Open lid");return false}))
            try guarder.perform {}
            XCTAssertEqual(writes,[state])
        }
    }
    func testCloseDuringFadeNeverReplaysUnblank() {
        var context=open;var closed:[UInt64]=[]
        let guarder=FadeKeyboardGuard(interface:.init(context:{context},keyboardStates:{[13:2,42:1]},setLogicalState:{_,_ in XCTFail("Closed lid");return false},setClosed:{id in closed.append(id);return true}))
        XCTAssertThrowsError(try guarder.perform {context = .init(lidClosed:true,sleeping:false,locked:false,generation:2)})
        XCTAssertEqual(closed,[13,42])
    }
    func testSleepAndLockAndReopenGenerationNeverReplayUnblank() {
        for next in [FadeSafetyContext(lidClosed:false,sleeping:true,locked:false,generation:2),.init(lidClosed:false,sleeping:false,locked:true,generation:2),.init(lidClosed:false,sleeping:false,locked:false,generation:3)] {
            var context=open;var states:[Int]=[]
            let g=FadeKeyboardGuard(interface:.init(context:{context},keyboardStates:{[13:2]},setLogicalState:{_,s in states.append(s);return true},setClosed:{_ in false}))
            XCTAssertThrowsError(try g.perform {context=next});XCTAssertEqual(states,[1])
        }
    }
    func testPartialFailureStillAttemptsEveryKeyboard() {
        var ids:[UInt64]=[]
        let g=FadeKeyboardGuard(interface:.init(context:{self.open},keyboardStates:{[13:2,42:1]},setLogicalState:{id,_ in ids.append(id);return id != 13},setClosed:{_ in false}))
        XCTAssertThrowsError(try g.perform {throw NSError(domain:"test",code:1)})
        XCTAssertEqual(ids,[13,42])
    }
    func testUnknownKeyboardStatePreventsGlobalFade() {
        let g=FadeKeyboardGuard(interface:.init(context:{self.open},keyboardStates:{nil},setLogicalState:{_,_ in false},setClosed:{_ in false}))
        XCTAssertThrowsError(try g.perform {XCTFail("No state snapshot")})
    }
    func testNewKeyboardIsNeverGivenOldUnblank() {
        var added=false;var writes:[UInt64:Int]=[:]
        let g=FadeKeyboardGuard(interface:.init(context:{self.open},keyboardStates:{added ? [13:2,42:2]:[13:2]},setLogicalState:{id,s in writes[id]=s;return true},setClosed:{_ in false}))
        // A new keyboard gets conservative Blank; does not inherit another's state.
        XCTAssertThrowsError(try g.perform {added=true})
        XCTAssertEqual(writes[13],2);XCTAssertEqual(writes[42],1)
    }
    func testIndependentRunnerAcknowledgesThenRestoresAfterParentDies() throws {
        let s=try store(),t=try prepared(s);var alive=true;var restored=false
        let result=FadeRecoveryWatchdog(store:s,token:t).run(watchdogPID:456,parentAlive:{_ in alive},leasePresent:{true},wait:{alive=false},restore:{_ in restored=true})
        XCTAssertEqual(result,0);XCTAssertTrue(restored)
    }
    func testCloseDuringKeyboardRestoreStopsLaterUnblank() {
        var context=open;var events:[String]=[]
        let g=FadeKeyboardGuard(interface:.init(context:{context},keyboardStates:{[13:2,42:2]},setLogicalState:{id,s in
            events.append("logical:\(id):\(s)");context = .init(lidClosed:true,sleeping:false,locked:false,generation:2);return true
        },setClosed:{id in events.append("closed:\(id)");return true}))
        XCTAssertThrowsError(try g.perform {})
        XCTAssertEqual(events,["logical:13:2","closed:42"])
    }

    func testAlreadySleepingOrLockedPreventsFadeWrite() {
        for context in [FadeSafetyContext(lidClosed:false,sleeping:true,locked:false,generation:1),.init(lidClosed:false,sleeping:false,locked:true,generation:1)] {
            let g=FadeKeyboardGuard(interface:.init(context:{context},keyboardStates:{[13:2]},setLogicalState:{_,_ in XCTFail("No writes");return false},setClosed:{_ in false}))
            XCTAssertThrowsError(try g.perform {XCTFail("No fade while asleep or locked")})
        }
    }

    func testHelperRetriesFailedRecoveryRatherThanAbandoningHardware() throws {
        let s=try store(),t=try prepared(s);var checks=0;var restores=0;var delays:[Double]=[];var reports=0
        let result=FadeRecoveryWatchdog(store:s,token:t).run(watchdogPID:456,parentAlive:{_ in checks += 1;return checks == 1},leasePresent:{true},wait:{},retryWait:{delays.append($0)},reportFailure:{_ in reports += 1},restore:{_ in
            restores += 1;if restores == 1 {throw NSError(domain:"test",code:1)}
        })
        XCTAssertEqual(result,0);XCTAssertEqual(restores,2);XCTAssertEqual(delays,[0.25]);XCTAssertEqual(reports,1)
    }
    func testPartialBatchPersistsFreshSnapshotNotSessionStartState() throws {
        let s=try store(),t=try prepared(s)
        try s.acknowledgeWatchdog(token:t,watchdogPID:456,parentAlive:{_ in true})
        let fresh=FadeBatchSnapshot(context:.init(lidClosed:false,sleeping:false,locked:false,generation:9),keyboardStates:[13:1])
        XCTAssertThrowsError(try s.withPermission(token:t,watchdogAlive:{_ in true},snapshot:fresh) {throw NSError(domain:"test",code:1)})
        XCTAssertEqual(try s.read().pendingBatch,fresh)
    }
    func testMissingPostWriteKeyboardReadStillAttemptsSavedKeyboards() {
        var after=false;var writes:[UInt64]=[]
        let g=FadeKeyboardGuard(interface:.init(context:{self.open},keyboardStates:{after ? nil:[13:2]},setLogicalState:{id,_ in writes.append(id);return true},setClosed:{_ in false}))
        XCTAssertThrowsError(try g.perform {after=true});XCTAssertEqual(writes,[13])
    }

    func testHelperSurvivesRealEffectLockTimeoutThenRecovers() throws {
        let s=try store(),t=try prepared(s)
        let acquired=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
        var parentAlive=true;var restored=false;var retries=0
        let result=FadeRecoveryWatchdog(store:s,token:t).run(watchdogPID:456,parentAlive:{_ in parentAlive},leasePresent:{true},wait:{
            DispatchQueue.global().async {
                defer {finished.signal()}
                _ = try? ClosedEffectSession.locked(directory:s.directory,wait:true) {
                    acquired.signal();_ = release.wait(timeout:.now()+5)
                }
            }
            XCTAssertEqual(acquired.wait(timeout:.now()+2),.success)
            parentAlive=false
        },retryWait:{_ in
            retries += 1;release.signal()
            XCTAssertEqual(finished.wait(timeout:.now()+2),.success)
        },restore:{_ in restored=true})
        XCTAssertEqual(result,0);XCTAssertEqual(retries,1);XCTAssertTrue(restored)
    }

}
