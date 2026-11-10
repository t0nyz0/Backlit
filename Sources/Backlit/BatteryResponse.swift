import Foundation

enum BatteryChargeStyle: String, Codable, CaseIterable, Identifiable {
    case level, steady, breathe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .level: return "Battery level"
        case .steady: return "Steady"
        case .breathe: return "Breathe"
        }
    }
}

enum BatteryReadyStyle: String, Codable, CaseIterable, Identifiable {
    case glow, pulse, blink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct BatteryResponseOptions: Codable, Equatable {
    var chargingStyle: BatteryChargeStyle = .level
    var readyEnabled = false
    var readyThreshold = 1.0
    var readyStyle: BatteryReadyStyle = .pulse
    var readyDuration = 10.0
}

/// A normalized multiplier. The caller still owns the brightness ceiling,
/// enable/pause policy, power-source sampling, and the animation timer.
struct BatteryResponse {
    private(set) var ready = false
    private(set) var completionActive = false
    private(set) var requiresAnimation = false
    private var previousExternalPower: Bool?
    private var previousTime: Double?
    private var previousThreshold: Double?
    private var previouslyEnabled = false
    private var completionStarted: Double?
    private var settledAtFull = false

    init() {}
    mutating func reset() { self = BatteryResponse() }

    mutating func update(charge: Double, externalPower: Bool, at time: Double,
                         options: BatteryResponseOptions) -> Double {
        guard charge.isFinite, time.isFinite else { reset(); return 0 }
        let amount = min(1, max(0, charge)), now = max(0, time)
        // Stay solid through small full-charge fluctuations while plugged in.
        if !externalPower || amount < 0.98 { settledAtFull = false }
        else if amount >= 1 { settledAtFull = true }
        let threshold = options.readyThreshold.isFinite ? min(1, max(0.5, options.readyThreshold)) : 1
        let duration = options.readyDuration.isFinite ? min(60, max(1, options.readyDuration)) : 10
        let staleClock = previousTime.map { now < $0 || now - $0 > 30 } ?? true
        let changedOptions = previousThreshold != threshold || previouslyEnabled != options.readyEnabled

        if staleClock || changedOptions {
            // Prime a new session; opening the app or editing a threshold is
            // not evidence that a battery just finished charging.
            ready = externalPower && amount >= threshold
            completionStarted = nil
        } else if !externalPower {
            ready = false
            completionStarted = nil
        } else {
            let wasReady = ready
            if ready {
                // A small drop around the threshold must not repeat a cue.
                if amount < max(0, threshold - 0.02) { ready = false }
            } else if amount >= threshold {
                ready = true
            }
            if options.readyEnabled && ready && (!wasReady || previousExternalPower == false) {
                completionStarted = now
            }
        }
        previousExternalPower = externalPower
        previousTime = now
        previousThreshold = threshold
        previouslyEnabled = options.readyEnabled

        completionActive = false
        if options.readyEnabled, externalPower, ready, let started = completionStarted {
            let elapsed = now - started
            if elapsed >= 0 && elapsed < duration {
                completionActive = true
                requiresAnimation = options.readyStyle != .glow
                switch options.readyStyle {
                case .glow: return 1
                case .pulse:
                    let phase = elapsed.truncatingRemainder(dividingBy: 1.6) / 1.6
                    return 0.25 + 0.75 * (1 - cos(2 * .pi * phase)) / 2
                case .blink:
                    let phase = elapsed.truncatingRemainder(dividingBy: 1.4)
                    return phase < 0.18 || (phase >= 0.34 && phase < 0.52) ? 1 : 0
                }
            }
        }
        completionStarted = nil
        requiresAnimation = externalPower && options.chargingStyle == .breathe && !settledAtFull
        guard externalPower else { return amount }
        switch options.chargingStyle {
        case .level: return amount
        case .steady: return 1
        case .breathe:
            guard !settledAtFull else { return 1 }
            let phase = now.truncatingRemainder(dividingBy: 6) / 6
            return 0.15 + 0.85 * (1 - cos(2 * .pi * phase)) / 2
        }
    }
}
