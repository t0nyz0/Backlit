import Foundation

enum GlowMode: String, CaseIterable, Codable, Identifiable {
    case steady, breathe, battery, music, agents, touch
    var id: String { rawValue }
    var title: String { self == .touch ? "Trackpad" : rawValue.capitalized }
    var symbol: String {
        switch self {
        case .steady: return "circle.fill"
        case .breathe: return "wind"
        case .battery: return "battery.75percent"
        case .music: return "waveform"
        case .agents: return "sparkles"
        case .touch: return "hand.tap"
        }
    }
}

enum AgentState: String, Codable { case waiting, working, attention }

struct EffectInput {
    var mode: GlowMode = .steady
    var enabled = true
    var brightness = 0.7
    var period = 6.0
    var battery = 1.0
    var batteryAvailable = true
    var externalPower = false
    var activelyCharging = false
    var audio = 0.0
    var intensity = 1.0
    var strobe = false
    var agent: AgentState = .waiting
    var away = false
    var touchDown = false
}

enum Effects {
    static func level(at time: Double, input: EffectInput) -> Double {
        guard input.enabled else { return 0 }
        let base = clamp(input.brightness)
        let t = time.isFinite ? max(0, time) : 0
        switch input.mode {
        case .steady: return base
        case .touch: return input.touchDown ? base : 0
        case .breathe:
            let cycle = max(3, min(10, input.period))
            return base * (0.04 + 0.96 * pow((1 - cos(2 * .pi * t / cycle)) / 2, 1.5))
        case .battery:
            guard input.batteryAvailable, input.battery.isFinite else { return 0 }
            let charge = clamp(input.battery)
            guard input.externalPower else { return base * charge }
            guard input.activelyCharging, charge < 1 else { return base }
            let phase = t.truncatingRemainder(dividingBy: 6) / 6
            return base * (0.15 + 0.85 * (1 - cos(2 * .pi * phase)) / 2)
        case .music:
            let energy = clamp(input.audio * max(0.25, min(3, input.intensity)))
            return base * (input.strobe ? (energy > 0.5 ? 1 : 0) : energy)
        case .agents:
            switch input.agent {
            case .waiting: return base * 0.18
            case .working: return base * (0.15 + 0.85 * (1 - cos(2 * .pi * t / 2.4)) / 2)
            case .attention:
                guard input.away else { return base * 0.5 }
                let phase = t.truncatingRemainder(dividingBy: 2)
                return base * ((phase < 0.13 || (phase >= 0.28 && phase < 0.41)) ? 1 : 0.08)
            }
        }
    }
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
}
