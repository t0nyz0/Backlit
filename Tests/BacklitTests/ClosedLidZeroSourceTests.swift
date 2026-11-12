import XCTest
@testable import Backlit

final class ClosedLidZeroSourceTests: XCTestCase {
    private typealias Fake = ClosedLidEffectTests.Fake
    private let gatedSources = [(0.0, 1.0), (856.0, 0.0), (0.0, 0.0)]

    func testInitialOffRequiresExplicitCommandEvenWithZeroFactorAndSource() throws {
        for (nits, multiplier) in gatedSources {
            let f = Fake(), effect = f.make()
            f.sample = .init(factor: 0, appliedNits: nits, multiplier: multiplier)
            try effect.apply(0)
            XCTAssertEqual(f.events, ["duration:5.0", "state:2", "keyboard", "duration:0.0", "state:1", "keyboard"])
            XCTAssertTrue(effect.active)
            XCTAssertTrue(effect.needsAnimation, "A pre-command zero sample cannot acknowledge Off")
            let count = f.events.count
            f.now = 10
            try effect.apply(0)
            XCTAssertFalse(effect.needsAnimation, "Observed exact zero must beat the elapsed endpoint deadline")
            XCTAssertEqual(f.events.count, count)
            f.sample = .init(factor: 0, appliedNits: 856, multiplier: 1)
            f.now = 20
            try effect.apply(0)
            XCTAssertEqual(f.events.count, count)
            XCTAssertFalse(effect.needsAnimation)
        }
    }

    func testZeroSourceDoesNotAcknowledgeNonzeroFactorAsOff() throws {
        for (nits, multiplier) in gatedSources {
            let f = Fake(), effect = f.make()
            f.sample = .init(factor: 0.0000009, appliedNits: nits, multiplier: multiplier)
            try effect.apply(0)
            XCTAssertTrue(effect.active)
            XCTAssertEqual(f.events.filter { $0.hasPrefix("state:") }, ["state:2", "state:1"])
            let count = f.events.count
            f.now = 2.99
            try effect.apply(0)
            XCTAssertTrue(effect.needsAnimation)
            f.now = 3
            XCTAssertThrowsError(try effect.apply(0)) { error in
                guard case FadeSessionInterruption.outputTimeout = error else { return XCTFail("Unexpected failure: \(error)") }
            }
            XCTAssertEqual(f.events.count, count)
            XCTAssertTrue(effect.active)
        }
    }

    func testPendingOffAcknowledgesExactFactorAfterSourceDrops() throws {
        for (nits, multiplier) in gatedSources {
            let f = Fake(), effect = f.make()
            try effect.apply(0)
            let count = f.events.count
            f.sample = .init(factor: 0, appliedNits: nits, multiplier: multiplier)
            f.now = 10
            try effect.apply(0)
            XCTAssertFalse(effect.needsAnimation)
            XCTAssertEqual(f.events.count, count)
        }
    }

    func testOffCancelsPendingRiseEvenWhenSourceDisappears() throws {
        let f = Fake(), effect = f.make()
        f.sample = .init(factor: 0, appliedNits: 856, multiplier: 1)
        try effect.apply(0.7)
        let count = f.events.count
        f.sample = .init(factor: 0, appliedNits: 0, multiplier: 1)
        f.now = 10
        try effect.apply(0)
        XCTAssertEqual(Array(f.events.dropFirst(count)), ["duration:0.0", "state:1", "keyboard"])
        XCTAssertTrue(effect.needsAnimation)
        try effect.apply(0)
        XCTAssertFalse(effect.needsAnimation)
    }

    func testOffResetsPriorSourceDeadlineBeforeNewPositiveRequest() throws {
        let f = Fake(), effect = f.make()
        f.sample = .init(factor: 0, appliedNits: 0, multiplier: 1)
        try effect.apply(0.7)
        f.now = 10
        try effect.apply(0)
        try effect.apply(0)
        let count = f.events.count
        f.now = 20
        try effect.apply(0.7)
        f.now = 22.99
        try effect.apply(0.7)
        XCTAssertEqual(f.events.count, count)
        f.now = 23
        XCTAssertThrowsError(try effect.apply(0.7))
    }

    func testPositiveTargetsStillRequireNativeSourceEvenAtExactFactor() throws {
        for (nits, multiplier) in gatedSources {
            for target in [0.005, 0.7, 1.0] {
                let f = Fake(), effect = f.make()
                f.sample = .init(factor: target, appliedNits: nits, multiplier: multiplier)
                try effect.apply(target)
                XCTAssertTrue(f.events.isEmpty)
                f.now = 3
                XCTAssertThrowsError(try effect.apply(target))
                XCTAssertTrue(f.events.isEmpty)
            }
        }
    }

    func testZeroSourceOffWriteFailureRetainsRecoveryOwnership() {
        for failed in ["duration:5.0", "state:2", "duration:0.0", "state:1", "keyboard"] {
            let f = Fake(), effect = f.make()
            f.sample = .init(factor: 0, appliedNits: 0, multiplier: 1)
            f.failedEvent = failed
            f.keyboardOK = failed != "keyboard"
            XCTAssertThrowsError(try effect.apply(0))
            XCTAssertTrue(effect.active)
            XCTAssertEqual(f.events.last, "keyboard")
        }
    }

    func testOffStillRejectsInvalidTelemetryBeforeWriting() {
        for sample in [ClosedLidEffect.Sample(factor: .nan, appliedNits: 0, multiplier: 1),
                       .init(factor: 0, appliedNits: -1, multiplier: 1),
                       .init(factor: 0, appliedNits: 0, multiplier: .infinity)] {
            let f = Fake(), effect = f.make()
            f.sample = sample
            XCTAssertThrowsError(try effect.apply(0))
            XCTAssertTrue(f.events.isEmpty)
        }
    }

    func testZeroSourceOffPlanIsInertAndOnlySettlesAfterExecution() throws {
        let f = Fake(), effect = f.make()
        f.sample = .init(factor: 0, appliedNits: 0, multiplier: 1)
        let plan = try effect.plan(0)
        XCTAssertEqual(plan.commands.map(\.state), [2, 1])
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertFalse(effect.active)
        try effect.execute(plan)
        XCTAssertTrue(effect.active)
        XCTAssertTrue(effect.needsAnimation)
        let count = f.events.count
        f.now = 10
        let settled = try effect.plan(0)
        XCTAssertFalse(settled.hasWrites)
        XCTAssertTrue(effect.needsAnimation)
        try effect.execute(settled)
        XCTAssertFalse(effect.needsAnimation)
        XCTAssertEqual(f.events.count, count)
    }
}
