#if BACKLIT_CONTROL_CENTER
import AppIntents
import Foundation

/// The switch reflects requested power, not instantaneous brightness (which can
/// be zero in a running effect). A stale or missing observation is not Off.
struct BacklitControlSnapshot: Codable {
    var schemaVersion: Int = 1
    let requestedEnabled: Bool
    let effectiveOutput: Bool
    let available: Bool
    var observedAt: Date = .now

    func isUsable(at now: Date) -> Bool {
        let age = now.timeIntervalSince(observedAt)
        return schemaVersion == 1 && available && (requestedEnabled || !effectiveOutput) && age.isFinite && age >= 0 && age <= 60
    }
}

enum BacklitControlError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "Backlit’s Control Center control is unavailable. Open Backlit to check its status.")
    }
}

enum BacklitControlState {
    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "BacklitControlAppGroup") as? String ?? ""
    }
    static let filename = "control-power-v1.json"
    static let kind = "local.backlit.control-center.power"

    static func currentValue() throws -> BacklitControlSnapshot {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier),
              let handle = try? FileHandle(forReadingFrom: directory.appendingPathComponent(filename)) else {
            throw BacklitControlError.unavailable
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097) else { throw BacklitControlError.unavailable }
        return try decode(data, now: .now)
    }

    static func decode(_ data: Data, now: Date) throws -> BacklitControlSnapshot {
        guard data.count <= 4096,
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(fields.keys) == ["schemaVersion", "requestedEnabled", "effectiveOutput", "available", "observedAt"],
              let snapshot = try? JSONDecoder().decode(BacklitControlSnapshot.self, from: data),
              snapshot.isUsable(at: now) else {
            throw BacklitControlError.unavailable
        }
        return snapshot
    }
}

@MainActor enum BacklitControlBridge {
    // Populated only in the containing app. The extension may read presentation
    // state but cannot accept a write or fall back to a different command path.
    static var setPower: ((Bool) throws -> Void)?

    static func perform(_ enabled: Bool) throws {
        guard let setPower else { throw BacklitControlError.unavailable }
        try setPower(enabled)
    }
}

@available(macOS 27.0, *)
struct SetBacklitControlPowerIntent: SetValueIntent {
    static var title: LocalizedStringResource { "Set Backlit Power" }
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
    // The host executes this control through macOS 27 main-target routing
    // without requesting activation or reopening its settings window.
    static let supportedModes: IntentModes = .background
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "On")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        try BacklitControlBridge.perform(value)
        return .result()
    }
}
#endif
