import Foundation
import SwiftUI

enum BatteryChargeStyle: String, Codable, CaseIterable, Identifiable {
    case breathe, steady, level
    var id: String { rawValue }
    var title: String {
        switch self {
        case .breathe: return "Automatic pulse"
        case .steady: return "Steady"
        case .level: return "Match battery level"
        }
    }
}

enum BatteryReadyStyle: String, Codable, CaseIterable, Identifiable {
    case glow, pulse, blink
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct BatteryResponseOptions: Codable, Equatable {
    var chargingStyle: BatteryChargeStyle = .breathe
    var pulsePeriod = 6.0
    var readyEnabled = false
    var readyThreshold = 1.0
    var readyStyle: BatteryReadyStyle = .pulse
    var readyDuration = 10.0
    enum CodingKeys: String, CodingKey { case chargingStyle, pulsePeriod, readyEnabled, readyThreshold, readyStyle, readyDuration }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        chargingStyle = (try? values.decode(BatteryChargeStyle.self, forKey: .chargingStyle)) ?? .breathe
        pulsePeriod = Self.bound((try? values.decode(Double.self, forKey: .pulsePeriod)) ?? 6, 3...10, fallback: 6)
        readyEnabled = (try? values.decode(Bool.self, forKey: .readyEnabled)) ?? false
        readyThreshold = Self.bound((try? values.decode(Double.self, forKey: .readyThreshold)) ?? 1, 0.5...1, fallback: 1)
        readyStyle = (try? values.decode(BatteryReadyStyle.self, forKey: .readyStyle)) ?? .pulse
        readyDuration = Self.bound((try? values.decode(Double.self, forKey: .readyDuration)) ?? 10, 1...60, fallback: 10)
    }
    static func bound(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

// Optional, bounded completion cue. It never fires merely because the app
// opens above a threshold, settings change, or the clock/session restarts.
struct BatteryReadySignal {
    private(set) var active = false
    private(set) var requiresAnimation = false
    private var ready = false
    private var previousTime: Double?
    private var previousExternalPower: Bool?
    private var previousOptions: BatteryResponseOptions?
    private var started: Double?
    mutating func reset() { self = BatteryReadySignal() }
    mutating func update(charge: Double, externalPower: Bool, at time: Double, options: BatteryResponseOptions) -> Double? {
        guard charge.isFinite, time.isFinite else { reset(); return nil }
        let amount = Effects.clamp(charge), now = max(0, time)
        let threshold = BatteryResponseOptions.bound(options.readyThreshold, 0.5...1, fallback: 1)
        let duration = BatteryResponseOptions.bound(options.readyDuration, 1...60, fallback: 10)
        let stale = previousTime.map { now < $0 || now - $0 > 30 } ?? true
        if stale || previousOptions != options {
            ready = externalPower && amount >= threshold; started = nil
        } else if !externalPower {
            ready = false; started = nil
        } else {
            let wasReady = ready
            if ready && amount < threshold - 0.02 { ready = false }
            else if amount >= threshold { ready = true }
            if options.readyEnabled && ready && (!wasReady || previousExternalPower == false) { started = now }
        }
        previousTime = now; previousExternalPower = externalPower; previousOptions = options
        active = false; requiresAnimation = false
        guard options.readyEnabled, externalPower, ready, let started, now - started < duration else {
            self.started = nil; return nil
        }
        active = true; requiresAnimation = options.readyStyle != .glow
        let elapsed = now - started
        switch options.readyStyle {
        case .glow: return 1
        case .pulse: return 0.25 + 0.75 * (1 - cos(2 * .pi * elapsed.truncatingRemainder(dividingBy: 1.6) / 1.6)) / 2
        case .blink:
            let phase = elapsed.truncatingRemainder(dividingBy: 1.4)
            return phase < 0.18 || (phase >= 0.34 && phase < 0.52) ? 1 : 0
        }
    }
}

struct BatterySettingsControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("While plugged in", selection: $model.batteryOptions.chargingStyle) {
                ForEach(BatteryChargeStyle.allCases) { style in Text(style.title).tag(style) }
            }.accessibilityLabel("Battery charging behavior")
            if model.batteryOptions.chargingStyle == .breathe {
                HStack { Text("Pulse cycle"); Spacer(); Text(String(format: "%.1f seconds", model.batteryOptions.pulsePeriod)).monospacedDigit() }
                Slider(value: $model.batteryOptions.pulsePeriod, in: 3...10, step: 0.5).accessibilityLabel("Battery pulse cycle seconds")
                Text("Pulses only while actively charging, then stays solid when charging pauses or finishes.").foregroundStyle(.secondary)
            } else if model.batteryOptions.chargingStyle == .steady {
                Text("No charging pulse. Holds your chosen brightness while plugged in.").foregroundStyle(.secondary)
            } else {
                Text("Follows the battery percentage while plugged in too.").foregroundStyle(.secondary)
            }
            Text("Unplugged, brightness follows battery charge down to 0%. Your brightness slider sets the upper limit.").foregroundStyle(.secondary)
            Divider()
            Toggle("Charge-ready signal", isOn: $model.batteryOptions.readyEnabled).toggleStyle(.switch).controlSize(.small)
            if model.batteryOptions.readyEnabled {
                HStack {
                    Text("Ready at")
                    Slider(value: $model.batteryOptions.readyThreshold, in: 0.5...1, step: 0.01).accessibilityLabel("Charge-ready threshold")
                    Text("\(Int((model.batteryOptions.readyThreshold * 100).rounded()))%").monospacedDigit()
                }
                Picker("Signal", selection: $model.batteryOptions.readyStyle) {
                    ForEach(BatteryReadyStyle.allCases) { style in Text(style.title).tag(style) }
                }
                Stepper("For \(Int(model.batteryOptions.readyDuration)) seconds", value: $model.batteryOptions.readyDuration, in: 1...60)
                Text("Optional: briefly overrides normal Battery behavior when charge reaches your threshold while plugged in. Does not repeat until charge drops or you unplug.").foregroundStyle(.secondary)
            }
            Button("Restore Battery Defaults") { model.batteryOptions = BatteryResponseOptions() }
                .disabled(model.batteryOptions == BatteryResponseOptions())
            Text("Default: automatic charging pulse, 6-second cycle, charge-ready signal off.").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.font(.system(size: 12))
    }
}
