import Foundation

/// Slider position changes perceptually while the saved intensity remains the
/// same 0.25...3 multiplier used by the effect engine.
enum MusicIntensity {
    static func multiplier(at position: Double) -> Double {
        0.25 * pow(12, Effects.clamp(position))
    }
    static func position(for multiplier: Double) -> Double {
        let value = multiplier.isFinite ? min(3, max(0.25, multiplier)) : 1
        return log(value / 0.25) / log(12)
    }
}

enum MusicResponsePreset: String, Codable, CaseIterable, Identifiable {
    case smooth, balanced, punchy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    fileprivate var attack: Double {
        switch self {
        case .smooth: return 0.08
        case .balanced: return 0.005
        case .punchy: return 0.002
        }
    }
    fileprivate var release: Double {
        switch self {
        case .smooth: return 0.25
        case .balanced: return 0.085
        case .punchy: return 0.04
        }
    }
    fileprivate var exponent: Double {
        switch self {
        case .smooth: return 0.8
        case .balanced: return 1
        case .punchy: return 1.7
        }
    }
}

/// Time-based adaptation of an existing bass-energy meter, not tempo/BPM
/// detection. No samples are retained. Output feeds the existing intensity
/// and strobe controls; the caller applies the overall brightness ceiling.
struct MusicResponse {
    private var previousTime: Double?
    private var reference = 0.25
    private var filtered = 0.0
    private(set) var adaptiveGain = 1.0

    init() {}
    mutating func reset() { self = MusicResponse() }

    mutating func update(energy: Double, at time: Double, automatic: Bool,
                         preset: MusicResponsePreset) -> Double {
        guard energy.isFinite, time.isFinite else { reset(); return 0 }
        let now = max(0, time)
        if let previousTime, now < previousTime || now - previousTime > 0.75 { reset() }
        // The stale-session guard already bounds elapsed time. Keeping the
        // actual interval lets release and gain catch up after a delayed frame.
        let dt = previousTime.map { max(0, now - $0) } ?? 0.05
        previousTime = now
        guard dt > 0 else { return filtered }
        let raw = min(1, max(0, energy))
        // Catch a new peak immediately, release its reference over seconds.
        // The gain bound and floor prevent quiet noise from chasing full output.
        reference = max(raw, max(0.04, reference * exp(-dt / 3)))
        // Leave headroom for the intensity control instead of normalizing
        // ordinary playback almost to the brightness ceiling immediately.
        adaptiveGain = automatic ? min(12.5, max(0.5, 0.6 / reference)) : 1
        let target = raw <= 0.008 ? 0 : pow(min(1, raw * adaptiveGain), preset.exponent)
        let constant = target > filtered ? preset.attack : preset.release
        filtered += (target - filtered) * (1 - exp(-dt / constant))
        if target == 0 && filtered < 0.001 { filtered = 0 }
        return min(1, max(0, filtered))
    }
}
