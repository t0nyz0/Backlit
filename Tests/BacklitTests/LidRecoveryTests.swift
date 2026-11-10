import XCTest
@testable import Backlit

final class LidRecoveryTests: XCTestCase {
    func testLogoOnlyRecordNeverChangesUnownedPowerState() throws {
        var events: [String] = []
        try LidRecovery(needsRestore: false, logoOverride: true).restore(
            logo: { events.append("logo") }, power: { events.append("power") })
        XCTAssertEqual(events, ["logo"])
    }
    func testLogoFailureStillRestoresNormalSleepAndRetainsFailure() {
        var powerCalled = false
        XCTAssertThrowsError(try LidRecovery(needsRestore: true, logoOverride: true).restore(
            logo: { throw NSError(domain: "logo", code: 1) }, power: { powerCalled = true }))
        XCTAssertTrue(powerCalled)
    }
    func testBothRestorationsFailWithoutDroppingEitherFailure() {
        var calls = 0
        XCTAssertThrowsError(try LidRecovery(needsRestore: true, logoOverride: true).restore(
            logo: { calls += 1; throw NSError(domain: "logo", code: 1) },
            power: { calls += 1; throw NSError(domain: "power", code: 1) }))
        XCTAssertEqual(calls, 2)
    }
    func testOlderPowerOnlyJournalDoesNotChangeLogo() throws {
        let record = try JSONDecoder().decode(LidRecovery.self, from: Data(#"{"needsRestore":true}"#.utf8))
        XCTAssertEqual(record, LidRecovery(needsRestore: true, logoOverride: false))
        var powerCalled = false
        try record.restore(logo: { XCTFail("Old journal owns no logo override") }, power: { powerCalled = true })
        XCTAssertTrue(powerCalled)
    }
    func testExplicitNormalSleepRepairIsHonoredWithoutOwnership() throws {
        var powerCalled = false
        try LidRecovery(needsRestore: false, logoOverride: false).restore(
            forceNormalSleep: true, logo: { XCTFail("No logo override") }, power: { powerCalled = true })
        XCTAssertTrue(powerCalled)
    }
    func testNoOwnershipHasNoSideEffects() throws {
        try LidRecovery(needsRestore: false, logoOverride: false).restore(
            logo: { XCTFail("No logo ownership") }, power: { XCTFail("No power ownership") })
    }
}
