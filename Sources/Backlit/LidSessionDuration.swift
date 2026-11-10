import Foundation

enum LidDurationMode: String, Codable, CaseIterable, Identifiable {
    case timed, untilTurnedOff
    var id: String { rawValue }
}

enum LidDurationUnit: String, Codable, CaseIterable, Identifiable {
    case minutes, hours
    var id: String { rawValue }
    var seconds: Int { self == .minutes ? 60 : 3600 }
    var maximum: Int { Int(LidSessionDuration.maximumSeconds) / seconds }
}

/// Only the duration preference persists. Starting a session remains an explicit action.
struct LidSessionDuration: Codable, Equatable {
    static let preferenceKey = "lid.sessionDuration"
    static let defaultSeconds = 1800.0
    static let maximumSeconds = 604800.0
    let mode: LidDurationMode
    let amount: Int
    let unit: LidDurationUnit

    init(mode: LidDurationMode = .timed, amount: Int = 30, unit: LidDurationUnit = .minutes) {
        self.mode = mode
        self.unit = unit
        self.amount = min(unit.maximum, max(1, amount))
    }

    var durationSeconds: Double { mode == .untilTurnedOff ? 0 : Double(amount * unit.seconds) }

    enum CodingKeys: String, CodingKey { case mode, amount, unit }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Corrupt or incomplete preferences must not opt into an unlimited session.
        guard let mode = try? values.decode(LidDurationMode.self, forKey: .mode),
              let amount = try? values.decode(Int.self, forKey: .amount),
              let unit = try? values.decode(LidDurationUnit.self, forKey: .unit),
              (1...unit.maximum).contains(amount) else {
            self.init()
            return
        }
        self.init(mode: mode, amount: amount, unit: unit)
    }

    func watcherArguments(parent: Int32, lease: URL) -> [String] {
        ["--watch-lid", String(parent), lease.path, String(Int(durationSeconds))]
    }
}

/// Strict parsing keeps a malformed helper invocation from launching the app UI.
/// Older callers omit seconds and retain the original 30-minute default.
struct LidWatcherArguments: Equatable {
    let parent: Int32
    let lease: URL
    let durationSeconds: Double

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--watch-lid") else { return nil }
        let values = Array(arguments.dropFirst(index + 1))
        guard values.count == 2 || values.count == 3,
              let parent = Int32(values[0]), parent > 0,
              values[1].hasPrefix("/"), !values[1].contains("\0") else { return nil }
        let seconds: Double
        if values.count == 3 {
            guard let parsed = Double(values[2]), parsed.isFinite,
                  parsed >= 0, parsed <= LidSessionDuration.maximumSeconds else { return nil }
            seconds = parsed
        } else { seconds = LidSessionDuration.defaultSeconds }
        self.parent = parent
        self.lease = URL(fileURLWithPath: values[1])
        self.durationSeconds = seconds
    }
}
