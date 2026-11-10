import Foundation

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
        let dt = previousTime.map { min(0.25, max(0, now - $0)) } ?? 0.05
        previousTime = now
        guard dt > 0 else { return filtered }
        let raw = min(1, max(0, energy))
        // Catch a new peak immediately, release its reference over seconds.
        // The gain bound and floor prevent quiet noise from chasing full output.
        reference = max(raw, max(0.04, reference * exp(-dt / 3)))
        adaptiveGain = automatic ? min(12.5, max(0.75, 0.9 / reference)) : 1
        let target = raw <= 0.008 ? 0 : pow(min(1, raw * adaptiveGain), preset.exponent)
        let constant = target > filtered ? preset.attack : preset.release
        filtered += (target - filtered) * (1 - exp(-dt / constant))
        if target == 0 && filtered < 0.001 { filtered = 0 }
        return min(1, max(0, filtered))
    }
}
