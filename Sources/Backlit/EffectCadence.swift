import Foundation

/// Slow effects retain continuous native interpolation with fewer feedback
/// samples. Music and interactive responses keep their existing 20 Hz cadence.
enum EffectCadence {
    static func animationInterval(for mode: GlowMode) -> Double {
        switch mode {
        case .steady, .breathe, .battery: return 0.1
        default: return 0.05
        }
    }
}
