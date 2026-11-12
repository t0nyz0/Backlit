import Foundation

enum LidDurationMode: String, Codable, CaseIterable, Identifiable {
    case timed, untilTurnedOff
    var id: String { rawValue }
}

enum LidDurationUnit: String, Codable, CaseIterable, Identifiable {
    case minutes, hours
    var id: String { rawValue }
    var seconds: Int { self == .minutes ? 60 : 3600 }
    var maximum: Int { max(1, Int(LidSessionDuration.maximumSeconds) / seconds) }
}

/// Duration preference is separate from the explicitly requested session.
struct LidSessionDuration: Codable, Equatable {
    static let preferenceKey = "lid.sessionDuration"
    static let defaultSeconds = 1800.0
    static let maximumSeconds = 1800.0
    static let legacyMaximumSeconds = 604800.0
    let mode: LidDurationMode
    let amount: Int
    let unit: LidDurationUnit

    init(mode: LidDurationMode = .timed, amount: Int = 30, unit: LidDurationUnit = .minutes) {
        // Old hours/unlimited values are accepted only as migration input.
        // Every live value is a finite count of minutes, at most thirty.
        self.mode = .timed
        self.unit = .minutes
        self.amount = mode == .untilTurnedOff ? 30 : unit == .hours && amount > 0 ? 30 : min(30, max(1, amount))
    }

    var durationSeconds: Double { Double(amount * 60) }

    enum CodingKeys: String, CodingKey { case mode, amount, unit }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Corrupt or incomplete preferences must not opt into an unlimited session.
        guard let mode = try? values.decode(LidDurationMode.self, forKey: .mode),
              let amount = try? values.decode(Int.self, forKey: .amount),
              let unit = try? values.decode(LidDurationUnit.self, forKey: .unit),
              amount > 0 else {
            self.init()
            return
        }
        self.init(mode: mode, amount: amount, unit: unit)
    }

    func watcherArguments(parent: Int32, lease: URL, intent: UUID? = nil) -> [String] {
        ["--watch-lid", String(parent), lease.path, String(Int(durationSeconds))] + (intent.map { [$0.uuidString] } ?? [])
    }
}

/// Strict parsing keeps a malformed helper invocation from launching the app UI.
/// Older callers omit seconds and retain the original 30-minute default.
struct LidWatcherArguments: Equatable {
    let parent: Int32
    let lease: URL
    let durationSeconds: Double
    let intent: UUID?

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--watch-lid") else { return nil }
        let values = Array(arguments.dropFirst(index + 1))
        guard (2...4).contains(values.count),
              let parent = Int32(values[0]), parent > 0,
              values[1].hasPrefix("/"), !values[1].contains("\0") else { return nil }
        let seconds: Double
        if values.count >= 3 {
            guard let parsed = Double(values[2]), parsed.isFinite,
                  LidSessionPolicy.validDuration(parsed) else { return nil }
            seconds = parsed
        } else { seconds = LidSessionDuration.defaultSeconds }
        self.parent = parent
        self.lease = URL(fileURLWithPath: values[1])
        self.durationSeconds = seconds
        if values.count == 4 {
            guard let intent = UUID(uuidString: values[3]) else { return nil }
            self.intent = intent
        } else { intent = nil }
    }
}
