import Foundation
import CoreFoundation

/// Bounds saved manual controls before they are bound to UI sliders. Missing
/// values retain existing defaults; invalid brightness stays dark and invalid
/// intensity uses the conservative engine floor.
struct EffectPreferenceValues {
    let brightness: Double
    let period: Double
    let intensity: Double

    init(brightness: Any?, period: Any?, intensity: Any?) {
        self.brightness = Self.bound(brightness, to: 0...1, missing: 0.68, invalid: 0)
        self.period = Self.bound(period, to: Effects.breathingPeriodRange, missing: 6, invalid: 6)
        self.intensity = Self.bound(intensity, to: 0.25...3, missing: 1, invalid: 0.25)
    }

    private static func bound(_ raw: Any?, to range: ClosedRange<Double>,
                              missing: Double, invalid: Double) -> Double {
        guard let raw else { return missing }
        let value: Double?
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            value = number.doubleValue
        } else if let text = raw as? String {
            // UserDefaults.double historically accepted numeric strings.
            value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else { value = nil }
        guard let value, value.isFinite else { return invalid }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
