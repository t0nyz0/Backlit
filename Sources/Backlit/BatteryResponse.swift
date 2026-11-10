import Foundation

/// Battery-driven output, independent of the saved manual brightness.
/// The caller owns enable/pause policy, power sampling, and animation timing.
struct BatteryResponse {
    private(set) var ready = false
    private(set) var completionActive = false
    private(set) var requiresAnimation = false
    private var previousExternalPower: Bool?
    private var previousTime: Double?
    private var previousOptions: BatteryResponseOptions?
    private var completionStarted: Double?
    private var settledAtFull = false
    private var pulseStartedAt: Double?

    init() {}
    mutating func reset() { self = BatteryResponse() }

    mutating func update(charge: Double, externalPower: Bool, at time: Double,
                         options: BatteryResponseOptions, activelyCharging: Bool = true) -> Double {
        guard charge.isFinite, time.isFinite else { reset(); return 0 }
        let amount = min(1, max(0, charge)), now = max(0, time)
        // Stay solid through small full-charge fluctuations while plugged in.
        if !externalPower || amount < 0.98 { settledAtFull = false }
        else if amount >= 1 { settledAtFull = true }
        let threshold = options.readyThreshold.isFinite ? min(1, max(0.5, options.readyThreshold)) : 1
        let duration = options.readyDuration.isFinite ? min(60, max(1, options.readyDuration)) : 10
        let staleClock = previousTime.map { now < $0 || now - $0 > 30 } ?? true
        let changedOptions = previousOptions != options

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
        previousOptions = options

        completionActive = false
        if options.readyEnabled, externalPower, ready, let started = completionStarted {
            let elapsed = now - started
            if elapsed >= 0 && elapsed < duration {
                completionActive = true
                pulseStartedAt = nil
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
        let minimum = BatteryResponseOptions.bound(options.pulseMinimum, 0...1, fallback: 0)
        requiresAnimation = externalPower && options.chargingStyle == .breathe && !settledAtFull && activelyCharging && minimum < 1
        if !requiresAnimation { pulseStartedAt = nil }
        guard externalPower else { return amount }
        switch options.chargingStyle {
        case .level: return amount
        case .steady: return 1
        case .breathe:
            guard !settledAtFull && activelyCharging else { return 1 }
            let cycle = BatteryResponseOptions.bound(options.pulsePeriod, 3...10, fallback: 6)
            if pulseStartedAt == nil || staleClock || changedOptions { pulseStartedAt = now }
            let elapsed = now - (pulseStartedAt ?? now)
            // Deliver the floor on the first available frame after a cycle,
            // including delayed/throttled frames. Restart smoothly from there.
            if elapsed >= cycle { pulseStartedAt = now; return minimum }
            let phase = elapsed / cycle
            // Keep a finite trough around each cycle boundary.
            let distance = min(phase, 1 - phase), hold = 0.08 / cycle
            let ramp = max(0, (distance - hold) / (0.5 - hold))
            return minimum + (1 - minimum) * (1 - cos(.pi * ramp)) / 2
        }
    }
}
