import Foundation

struct ActivitySignalEngine {
    private struct Entry {
        var signal: ActivitySignal
        var started: Double
        var expires: Double
    }
    private var entries: [ActivityCategory: Entry] = [:]
    private(set) var current: ActivitySignal?
    private(set) var requiresAnimation = false
    private(set) var count = 0
    private var lastTime: Double?

    mutating func submit(_ signal: ActivitySignal, at time: Double) {
        guard time.isFinite else { return }
        if let lastTime, time < lastTime { reset() }
        lastTime = time
        if signal.state == .clear { entries.removeValue(forKey: signal.category) }
        else { entries[signal.category] = Entry(signal: signal, started: time, expires: time + signal.effectiveDuration) }
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        current = nil
        requiresAnimation = false
        count = 0
        lastTime = nil
    }

    mutating func level(at time: Double) -> Double {
        guard time.isFinite else { reset(); return 0 }
        if let lastTime, time < lastTime { reset() }
        lastTime = time
        for (category, entry) in entries where time >= entry.expires {
            if category == .focus, entry.signal.state == .active, time - entry.expires < 8,
               let completed = try? ActivitySignal(category: .focus, state: .complete, duration: 8, progress: nil) {
                entries[category] = Entry(signal: completed, started: entry.expires, expires: entry.expires + 8)
            } else { entries.removeValue(forKey: category) }
        }
        let selected = entries.values.max {
            let lhs = priority($0.signal), rhs = priority($1.signal)
            if lhs != rhs { return lhs < rhs }
            if $0.started != $1.started { return $0.started < $1.started }
            return $0.signal.category.rawValue < $1.signal.category.rawValue
        }
        current = selected?.signal
        count = entries.count
        requiresAnimation = selected?.signal.state == .complete || selected?.signal.state == .attention
        guard let entry = selected else { return 0 }
        let elapsed = max(0, time - entry.started)
        switch entry.signal.state {
        case .clear: return 0
        case .active:
            let progress = entry.signal.progress ?? (entry.signal.category == .focus ? elapsed / entry.signal.effectiveDuration : nil)
            return progress.map { 0.18 + 0.82 * Effects.clamp($0) } ?? 0.75
        case .complete: return 0.3 + 0.7 * (1 - cos(2 * .pi * elapsed / 1.6)) / 2
        case .attention:
            let phase = elapsed.truncatingRemainder(dividingBy: 2)
            return phase < 0.13 || (phase >= 0.28 && phase < 0.41) ? 1 : 0.08
        }
    }

    private func priority(_ signal: ActivitySignal) -> Int {
        switch signal.state {
        case .attention: return 4
        case .complete: return 3
        case .active: return signal.category == .focus ? 1 : 2
        case .clear: return 0
        }
    }
}
