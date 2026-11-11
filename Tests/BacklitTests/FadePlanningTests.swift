import XCTest
@testable import Backlit
final class FadePlanningTests:XCTestCase {
    func testPlanningIsInertAndPlanCannotExecuteTwice() throws {
        var writes=0,keyboards=0
        let effect=ClosedLidEffect(interface:.init(sample:{.init(factor:0.5,appliedNits:100,multiplier:1)},duration:{_ in writes+=1;return true},logicalState:{_ in writes+=1;return true},keepKeyboardDark:{keyboards+=1;return true}))
        let plan=try effect.plan(0.4)
        XCTAssertTrue(plan.hasWrites);XCTAssertEqual(writes,0);XCTAssertEqual(keyboards,0)
        try effect.execute(plan);XCTAssertGreaterThan(writes,0)
        let count=writes;XCTAssertThrowsError(try effect.execute(plan));XCTAssertEqual(writes,count)
    }
    func testNoWriteFrameDoesNotCallKeyboardOrGlobalSetters() throws {
        var factor=0.5,writes=0,keyboards=0
        let effect=ClosedLidEffect(interface:.init(sample:{.init(factor:factor,appliedNits:100,multiplier:1)},duration:{_ in writes+=1;return true},logicalState:{_ in writes+=1;return true},keepKeyboardDark:{keyboards+=1;return true}))
        try effect.execute(effect.plan(0))
        factor=0;let settled=try effect.plan(0)
        XCTAssertFalse(settled.hasWrites)
        let globalCount=writes,keyboardCount=keyboards
        try effect.execute(settled)
        XCTAssertEqual(writes,globalCount);XCTAssertEqual(keyboards,keyboardCount)
        XCTAssertFalse(effect.needsAnimation)
    }
    func testPartialSecondCommandFailureRetainsOwnershipAndInvalidatesPlan() throws {
        var calls=0
        let effect=ClosedLidEffect(interface:.init(sample:{.init(factor:0.5,appliedNits:100,multiplier:1)},duration:{_ in true},logicalState:{_ in calls+=1;return calls<2},keepKeyboardDark:{true}))
        let plan=try effect.plan(0)
        XCTAssertEqual(plan.commands.count,2)
        XCTAssertThrowsError(try effect.execute(plan));XCTAssertTrue(effect.active)
        XCTAssertThrowsError(try effect.execute(plan));XCTAssertEqual(calls,2)
    }
    func testGuardedPartialFrameRestoresEveryKeyboardWithoutInnerDuplicates() throws {
        let context=FadeSafetyContext(lidClosed:true,sleeping:false,locked:false,generation:1)
        var states=0,closedIDs:[UInt64]=[]
        let effect=ClosedLidEffect(interface:.init(sample:{.init(factor:0.5,appliedNits:100,multiplier:1)},duration:{_ in true},logicalState:{_ in states+=1;return states<2},keepKeyboardDark:{true}))
        let plan=try effect.plan(0)
        let guarder=FadeKeyboardGuard(interface:.init(context:{context},keyboardStates:{[13:1,42:1]},setLogicalState:{_,_ in XCTFail("Closed keyboard");return false},setClosed:{closedIDs.append($0);return true}))
        XCTAssertThrowsError(try guarder.perform {try effect.execute(plan)})
        XCTAssertEqual(Set(closedIDs),Set([13,42]));XCTAssertEqual(closedIDs.count,2)
        XCTAssertTrue(effect.active)
    }
    func testNoWritePermissionSkipsSnapshotJournalAndBody() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=FadeRecoveryStore(directory:dir)
        let context=FadeSafetyContext(lidClosed:false,sleeping:false,locked:false,generation:1)
        let token=try store.prepare(parentPID:1,context:context,keyboards:[13:2])
        try store.acknowledgeWatchdog(token:token,watchdogPID:2,parentAlive:{_ in true})
        let before=try Data(contentsOf:store.url)
        let _:Bool? = try store.withPermission(token:token,watchdogAlive:{_ in true},snapshotProvider:{XCTFail("No-write snapshot");return .init(context:context,keyboardStates:[13:2])},shouldWrite:{false}) {XCTFail("No-write body");return true}
        XCTAssertEqual(try Data(contentsOf:store.url),before)
    }
    func testSafetyGenerationChangeBeforeExecutionRetainsJournalWithoutWrites() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=FadeRecoveryStore(directory:dir)
        let context=FadeSafetyContext(lidClosed:false,sleeping:false,locked:false,generation:1)
        let changed=FadeSafetyContext(lidClosed:false,sleeping:false,locked:false,generation:2)
        let token=try store.prepare(parentPID:1,context:context,keyboards:[13:2])
        try store.acknowledgeWatchdog(token:token,watchdogPID:2,parentAlive:{_ in true})
        var current=context,writes=0
        XCTAssertThrowsError(try store.withPermission(token:token,watchdogAlive:{_ in true},snapshotProvider:{current=changed;return .init(context:context,keyboardStates:[13:2])},shouldWrite:{true}) {
            guard current==context else {throw NSError(domain:"generation",code:1)}
            writes+=1
        })
        XCTAssertEqual(writes,0);XCTAssertNotNil(try store.read().pendingBatch)
    }
}
