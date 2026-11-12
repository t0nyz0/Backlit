import XCTest
@testable import Backlit

final class NativeLightSampleTests: XCTestCase {
    private var valid: [String: Any] { ["Factor": 0.5, "AppliedNits": 12.0, "NitsMultiplier": 0.2] }

    private func assertFailure(_ raw: Any?, _ field: NativeLightSample.Failure.Field,
                               _ reason: NativeLightSample.Failure.Reason,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try NativeLightSample.sample(raw), file: file, line: line) {
            XCTAssertEqual(($0 as? NativeLightSample.Failure)?.field, field, file: file, line: line)
            XCTAssertEqual(($0 as? NativeLightSample.Failure)?.reason, reason, file: file, line: line)
        }
    }

    func testOnlyRequiredFieldsAreInspected() throws {
        var state = valid
        state["Unrelated"] = ["metadata": "not a number"]
        state["Other"] = NSNull()
        XCTAssertEqual(try NativeLightSample.sample(state).factor, 0.5)
        XCTAssertEqual(try NativeLightSample.factor(["Factor": 0.25, "AppliedNits": "ignored"]), 0.25)
        let nonStringKey = NSDictionary(objects: [NSNumber(value: 0.7), "unrelated"], forKeys: ["Factor" as NSString, NSNumber(value: 4)])
        XCTAssertEqual(try NativeLightSample.factor(nonStringKey), 0.7)
    }

    func testZerosAndEndpointsRemainValid() throws {
        for factor in [0.0, 1.0] {
            let sample = try NativeLightSample.sample(["Factor": factor, "AppliedNits": 0.0, "NitsMultiplier": 0.0])
            XCTAssertEqual(sample.factor, factor)
            XCTAssertEqual(sample.appliedNits, 0)
            XCTAssertEqual(sample.multiplier, 0)
        }
    }

    func testContainerAndEachRequiredFieldFailures() {
        assertFailure(nil, .state, .missing)
        assertFailure("not a dictionary", .state, .malformed)
        for (key, field) in [("Factor", NativeLightSample.Failure.Field.factor), ("AppliedNits", .appliedNits), ("NitsMultiplier", .multiplier)] {
            var state = valid
            state.removeValue(forKey: key)
            assertFailure(state, field, .missing)
            for value in ["0", NSNull(), [0]] as [Any] {
                state[key] = value
                assertFailure(state, field, .malformed)
            }
            for value in [true, false] {
                state[key] = value
                assertFailure(state, field, .boolean)
            }
            for value in [Double.nan, .infinity, -.infinity] {
                state[key] = value
                assertFailure(state, field, .nonfinite)
            }
            state[key] = -0.1
            assertFailure(state, field, field == .factor ? .outOfRange : .negative)
        }
        var state = valid
        state["Factor"] = 1.001
        assertFailure(state, .factor, .outOfRange)
        state = valid
        state["AppliedNits"] = Double.greatestFiniteMagnitude
        state["NitsMultiplier"] = 2.0
        assertFailure(state, .product, .nonfinite)
    }

    func testFactorOnlyReadStillRejectsInvalidFactors() {
        for value in [true, "0.5", Double.nan, Double.infinity, -0.1, 1.1] as [Any] {
            XCTAssertThrowsError(try NativeLightSample.factor(["Factor": value]))
        }
        XCTAssertThrowsError(try NativeLightSample.factor(["Other": 0]))
    }

    func testFailureDiagnosticsAreBoundedAndContainOnlyKnownLabels() {
        var messages: [String] = []
        let diagnostic = NativeLightSampleDiagnostics(source: .closedEffect, emit: { messages.append($0) })
        for _ in 0..<100 {
            diagnostic.record(.init(field: .appliedNits, reason: .malformed))
        }
        XCTAssertEqual(messages.count, 8)
        XCTAssertEqual(messages.first, "Native sample rejected [closedEffect] AppliedNits:malformed")
        XCTAssertTrue(messages.last!.hasSuffix("diagnostic limit reached"))
    }

    func testNumericFailureDiagnosticsPreserveBoundedExactValues() {
        let cases: [(Double, String)] = [
            (1.0.nextUp, "0x3ff0000000000001"),
            (1000, "0x408f400000000000"),
            (-1, "0xbff0000000000000"),
            (.nan, "NaN"), (.infinity, "+infinity"), (-.infinity, "-infinity")
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try NativeLightSample.factor(["Factor": value])) { error in
                let failure = error as! NativeLightSample.Failure
                XCTAssertEqual(failure.numericValue, expected)
                XCTAssertLessThanOrEqual(failure.numericValue!.count, 18)
                var messages: [String] = []
                let diagnostics = NativeLightSampleDiagnostics(source: .fadeFactor, emit: { messages.append($0) })
                for _ in 0..<12 { diagnostics.record(failure) }
                XCTAssertEqual(messages.count, 8)
                XCTAssertTrue(messages[0].hasSuffix("value=\(expected)"))
            }
        }
        let overflow = NativeLightSample.validationFailure(.init(factor: 0.5, appliedNits: .greatestFiniteMagnitude, multiplier: 2))
        XCTAssertEqual(overflow?.summary, "AppliedNits*NitsMultiplier:nonfinite value=+infinity")
        let negative = NativeLightSample.validationFailure(.init(factor: 0.5, appliedNits: -1, multiplier: 1))
        XCTAssertEqual(negative?.summary, "AppliedNits:negative value=0xbff0000000000000")
    }

    func testNonnumericFailuresNeverIncludeNativeValues() {
        for raw in ["private unexpected text", NSNull(), true] as [Any] {
            XCTAssertThrowsError(try NativeLightSample.factor(["Factor": raw])) { error in
                let failure = error as! NativeLightSample.Failure
                XCTAssertNil(failure.numericValue)
                XCTAssertFalse(failure.summary.contains("value="))
                XCTAssertFalse(failure.summary.contains("private"))
            }
        }
    }

    func testInvalidSampleDoesNotWriteOrActivateClosedEffect() {
        for sample in [NativeLightSample.Sample(factor: .nan, appliedNits: 1, multiplier: 1),
                       .init(factor: 0.5, appliedNits: -1, multiplier: 1),
                       .init(factor: 0.5, appliedNits: .greatestFiniteMagnitude, multiplier: 2)] {
            var writes = 0
            let effect = ClosedLidEffect(interface: .init(sample: { sample }, duration: { _ in writes += 1; return true }, logicalState: { _ in writes += 1; return true }, keepKeyboardDark: { writes += 1; return true }))
            XCTAssertThrowsError(try effect.apply(0.5))
            XCTAssertEqual(writes, 0)
            XCTAssertFalse(effect.active)
        }
    }
}
