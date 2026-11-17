import Foundation
import CoreFoundation
import OSLog

/// Reads only the native fields used by the caller. Unrelated native metadata
/// must not invalidate a sample, and missing/Boolean values are never zero.
enum NativeLightSample {
    struct Sample {
        let factor: Double
        enum Source { case baseline(appliedNits: Double, multiplier: Double), measuredOutput(finalNits: Double) }
        let source: Source
        init(factor: Double, appliedNits: Double, multiplier: Double) {
            self.factor = factor; source = .baseline(appliedNits: appliedNits, multiplier: multiplier)
        }
        init(factor: Double, finalNits: Double) {
            self.factor = factor; source = .measuredOutput(finalNits: finalNits)
        }
        var positiveSourceObserved: Bool {
            switch source {
            case let .baseline(nits, multiplier): return nits > 0 && multiplier > 0
            case let .measuredOutput(nits): return nits > 0
            }
        }
        // FinalNits includes the fade factor. Zero at factor zero is unknown
        // source availability, not a proven zero baseline. A guarded bounded
        // first-rise attempt is allowed, but cannot be reported as output.
        var canAttemptFirstRise: Bool {
            if case .measuredOutput = source { return factor == 0 }
            return false
        }
    }
    struct Failure: Error, Equatable {
        enum Field: String { case finalNits = "FinalNits", state = "LEPWMState", factor = "Factor", appliedNits = "AppliedNits", multiplier = "NitsMultiplier", product = "AppliedNits*NitsMultiplier" }
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
        let factor = try number(.factor, in: state)
        let value: Sample
        if state["AppliedNits"] == nil && state["NitsMultiplier"] == nil && state["FinalNits"] != nil {
            value = Sample(factor: factor, finalNits: try number(.finalNits, in: state))
        } else {
            // Never hide a partial or malformed baseline behind another field.
            value = Sample(factor: factor, appliedNits: try number(.appliedNits, in: state),
                           multiplier: try number(.multiplier, in: state))
        }
        if let failure = validationFailure(value) { throw failure }
        return value
    }

    static func validationFailure(_ value: Sample) -> Failure? {
        if let failure = validationFailure(value.factor, field: .factor) { return failure }
        switch value.source {
        case let .measuredOutput(nits): return validationFailure(nits, field: .finalNits)
        case let .baseline(nits, multiplier):
            if let failure = validationFailure(nits, field: .appliedNits) { return failure }
            if let failure = validationFailure(multiplier, field: .multiplier) { return failure }
            guard (nits * multiplier).isFinite else {
                return Failure(field: .product, reason: .nonfinite, value: nits * multiplier)
            }
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
