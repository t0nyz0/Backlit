import XCTest
@testable import Backlit

final class LidRepairTests: XCTestCase {
    func testSuccessfulForcedResetDoesNotRequireAggregateSleepPolicy() throws {
        // A docked Mac may keep AppleClamshellCausesSleep false or omit the
        // property. Repair requires successful restoration, not that property.
        var events: [String] = []
        try RuntimeServices.repairLid(record: .init(needsRestore: false, logoOverride: true),
            forcePowerRestore: true, logo: { events.append("logo") },
            power: { events.append("power") }, removeJournal: { events.append("remove") })
        XCTAssertEqual(events, ["logo", "power", "remove"])
    }

    func testPowerFailureRetainsJournal() {
        var removed = false
        XCTAssertThrowsError(try RuntimeServices.repairLid(
            record: .init(needsRestore: true, logoOverride: false),
            logo: { XCTFail("No logo ownership") },
            power: { throw NSError(domain: "power", code: 1) },
            removeJournal: { removed = true }))
        XCTAssertFalse(removed)
    }

    func testLogoFailureStillAttemptsPowerAndRetainsJournal() {
        var powerCalled = false
        var removed = false
        XCTAssertThrowsError(try RuntimeServices.repairLid(
            record: .init(needsRestore: true, logoOverride: true),
            logo: { throw NSError(domain: "logo", code: 1) },
            power: { powerCalled = true }, removeJournal: { removed = true }))
        XCTAssertTrue(powerCalled)
        XCTAssertFalse(removed)
    }

    func testOrdinaryLogoOnlyRepairDoesNotResetUnownedPower() throws {
        var events: [String] = []
        try RuntimeServices.repairLid(record: .init(needsRestore: false, logoOverride: true),
            logo: { events.append("logo") }, power: { XCTFail("No power ownership") },
            removeJournal: { events.append("remove") })
        XCTAssertEqual(events, ["logo", "remove"])
    }

    func testExplicitRepairWithoutJournalStillResetsPower() throws {
        var powerCalled = false
        try RuntimeServices.repairLid(record: nil, forcePowerRestore: true,
            logo: { XCTFail("No logo ownership") }, power: { powerCalled = true },
            removeJournal: { XCTFail("No journal exists") })
        XCTAssertTrue(powerCalled)
    }

    func testNoJournalAndNoForceHasNoSideEffects() throws {
        try RuntimeServices.repairLid(record: nil,
            logo: { XCTFail("No logo ownership") }, power: { XCTFail("No power ownership") },
            removeJournal: { XCTFail("No journal exists") })
    }

    func testJournalRemovalFailureIsReported() {
        XCTAssertThrowsError(try RuntimeServices.repairLid(
            record: .init(needsRestore: false, logoOverride: false),
            logo: { XCTFail("No logo ownership") }, power: { XCTFail("No power ownership") },
            removeJournal: { throw NSError(domain: "journal", code: 1) }))
    }
}
