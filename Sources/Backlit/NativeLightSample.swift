import Foundation
import CoreFoundation
import OSLog

/// Reads only the native fields used by the caller. Unrelated native metadata
/// must not invalidate a sample, and missing/Boolean values are never zero.
enum NativeLightSample {
    struct Sample {
        let factor: Double
        let appliedNits: Double
        let multiplier: Double
    }
    struct Failure: Error, Equatable {
        enum Field: String { case state = "LEPWMState", factor = "Factor", appliedNits = "AppliedNits", multiplier = "NitsMultiplier", product = "AppliedNits*NitsMultiplier" }
        enum Reason: String { case missing, malformed, boolean, nonfinite, outOfRange, negative }
        let field: Field
        let reason: Reason
        // Derived only from a Double, never from native object descriptions.
        // Finite IEEE-754 bits preserve exact values in at most 18 characters.
        let numericValue: String?
        init(field: Field, reason: Reason, value: Double? = nil) {
            self.field = field
            self.reason = reason
            if let value {
                if value.isNaN { numericValue = "NaN" }
                else if value == .infinity { numericValue = "+infinity" }
                else if value == -.infinity { numericValue = "-infinity" }
                else {
                    let bits = String(value.bitPattern, radix: 16)
                    numericValue = "0x" + String(repeating: "0", count: 16 - bits.count) + bits
                }
            } else { numericValue = nil }
        }
        var summary: String {
            "\(field.rawValue):\(reason.rawValue)" + (numericValue.map { " value=\($0)" } ?? "")
        }
    }

    static func factor(_ raw: Any?) throws -> Double {
        try number(.factor, in: dictionary(raw))
    }

    static func sample(_ raw: Any?) throws -> Sample {
        let state = try dictionary(raw)
        let value = Sample(factor: try number(.factor, in: state),
                           appliedNits: try number(.appliedNits, in: state),
                           multiplier: try number(.multiplier, in: state))
        if let failure = validationFailure(value) { throw failure }
        return value
    }

    static func validationFailure(_ value: Sample) -> Failure? {
        for (field, number) in [(Failure.Field.factor, value.factor), (.appliedNits, value.appliedNits), (.multiplier, value.multiplier)] {
            if let failure = validationFailure(number, field: field) { return failure }
        }
        guard (value.appliedNits * value.multiplier).isFinite else {
            return Failure(field: .product, reason: .nonfinite, value: value.appliedNits * value.multiplier)
        }
        return nil
    }

    private static func dictionary(_ raw: Any?) throws -> NSDictionary {
        guard let raw else { throw Failure(field: .state, reason: .missing) }
        guard let state = raw as? NSDictionary else { throw Failure(field: .state, reason: .malformed) }
        return state
    }

    private static func number(_ field: Failure.Field, in state: NSDictionary) throws -> Double {
        guard let raw = state[field.rawValue] else { throw Failure(field: field, reason: .missing) }
        guard let number = raw as? NSNumber else { throw Failure(field: field, reason: .malformed) }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { throw Failure(field: field, reason: .boolean) }
        let value = number.doubleValue
        if let failure = validationFailure(value, field: field) { throw failure }
        return value
    }

    private static func validationFailure(_ value: Double, field: Failure.Field) -> Failure? {
        guard value.isFinite else { return Failure(field: field, reason: .nonfinite, value: value) }
        if field == .factor {
            guard (0...1).contains(value) else { return Failure(field: field, reason: .outOfRange, value: value) }
        } else if value < 0 { return Failure(field: field, reason: .negative, value: value) }
        return nil
    }
}

/// Failure-only, local diagnostics with a fixed lifetime budget per interface.
/// No raw dictionaries, arbitrary values, keyboard IDs or preferences are logged.
final class NativeLightSampleDiagnostics {
    enum Source: String { case closedEffect, fadeFactor }
    private let lock = NSLock()
    private var remaining = 8
    private let source: Source
    private let emit: (String) -> Void
    init(source: Source, emit: ((String) -> Void)? = nil) {
        self.source = source
        self.emit = emit ?? { message in
            Logger(subsystem: "local.backlit", category: "native-sample").error("\(message, privacy: .public)")
        }
    }
    func record(_ failure: NativeLightSample.Failure) {
        lock.lock()
        guard remaining > 0 else { lock.unlock(); return }
        remaining -= 1
        let last = remaining == 0
        lock.unlock()
        emit("Native sample rejected [\(source.rawValue)] \(failure.summary)" + (last ? "; diagnostic limit reached" : ""))
    }
}
