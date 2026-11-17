import Foundation

enum MCPAccess: String, CaseIterable, Identifiable, Codable, Sendable {
    case off, status, control
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .status: return "Status only"
        case .control: return "Allow light changes"
        }
    }
}

struct ExternalControlError: Error, LocalizedError, Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case accessDisabled = "ACCESS_DISABLED", authRequired = "AUTH_REQUIRED"
        case appNotRunning = "APP_NOT_RUNNING", invalidArgument = "INVALID_ARGUMENT"
        case hardwareUnavailable = "HARDWARE_UNAVAILABLE", recoveryRequired = "RECOVERY_REQUIRED"
        case permissionRequired = "PERMISSION_REQUIRED", busy = "BUSY", paused = "PAUSED"
        case brightnessAutomatic = "BRIGHTNESS_AUTOMATIC", rateLimited = "RATE_LIMITED"
        case unavailable = "UNAVAILABLE"
    }
    let code: Code
    let message: String
    var errorDescription: String? { message }
    init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

/// Snapshot used by every external control route. No permission requests or
/// hardware actions occur during validation; the complete target is checked first.
struct ExternalControlContext {
    static func recoveryRequired(controlling: Bool, journalPresent: Bool, failurePresent: Bool) -> Bool {
        // Active ownership normally has a recovery journal. Its presence is
        // exceptional only after ownership was lost or an operation failed.
        failurePresent || (!controlling && journalPresent)
    }
    var hardwareAvailable = false
    var controlWanted = false
    var controlling = false
    var needsRecovery = false
    var busy = false
    var paused: String?
    var mode: GlowMode = .steady
    var enabled = true
    var availableModes: [GlowMode] = []
    var musicAuthorized = false
    var typingAuthorized = false

    func validate(_ command: LightCommand, rejectAutomaticBrightness: Bool = true) throws {
        guard command.enabled != nil || command.brightness != nil || command.mode != nil else {
            throw ExternalControlError(.invalidArgument, "Supply a light setting.")
        }
        if let brightness = command.brightness, !brightness.isFinite || !(0...1).contains(brightness) {
            throw ExternalControlError(.invalidArgument, "Brightness must be a finite percentage from 0 to 100.")
        }
        guard !needsRecovery else {
            throw ExternalControlError(.recoveryRequired, "Restore your light in Backlit before using external controls.")
        }
        guard !busy else { throw ExternalControlError(.busy, "Backlit is finishing a hardware operation. Read status before retrying.") }
        guard hardwareAvailable, controlWanted else {
            throw ExternalControlError(.hardwareUnavailable, "Open Backlit on a compatible Mac and connect its light first.")
        }
        let offOnly = command.enabled == false && command.brightness == nil && command.mode == nil
        if !offOnly {
            if let paused { throw ExternalControlError(.paused, paused) }
            guard controlling else { throw ExternalControlError(.hardwareUnavailable, "Backlit is waiting to control its light. Read status before retrying.") }
        }
        let targetMode = command.mode ?? mode
        let targetEnabled = command.enabled ?? enabled
        if let selected = command.mode, !availableModes.contains(selected) {
            throw ExternalControlError(.invalidArgument, "That behavior is unavailable on this Mac.")
        }
        if rejectAutomaticBrightness, command.brightness != nil, targetMode == .battery {
            throw ExternalControlError(.brightnessAutomatic, "Battery mode controls its own output. Select a manual mode before setting brightness.")
        }
        if targetMode == .music, (targetEnabled || command.mode != nil), !musicAuthorized {
            throw ExternalControlError(.permissionRequired, "Select Music in Backlit and allow system audio before using Music remotely.")
        }
        if targetMode == .typing, (targetEnabled || command.mode != nil), !typingAuthorized {
            throw ExternalControlError(.permissionRequired, "Enable typing access in Backlit before selecting Typing remotely.")
        }
    }
}

/// Limit agent updates, not the app's own animation frames. The app enforces
/// this across all stdio processes; restarting a client does not reset the limit.
struct ExternalControlRateLimit {
    private var tokens = 4.0
    private var last: TimeInterval?
    mutating func admit(at now: TimeInterval) -> Bool {
        guard now.isFinite else { return false }
        if let last { tokens = min(4, tokens + max(0, now - last) * 2) }
        last = max(last ?? now, now)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

struct AgentLightState: Codable, Sendable, Equatable {
    struct Mode: Codable, Sendable, Equatable {
        let name: String
        let selectable: Bool
        let reason: String?
    }
    let access: MCPAccess
    let enabled: Bool
    let mode: String
    let manualBrightnessPercent: Double
    let calculatedOutputPercent: Double
    let hardwareEnabled: Bool?
    let hardwareSampleAgeSeconds: Double?
    let hardwareSupported: Bool
    let controlling: Bool
    let preview: Bool
    let recoveryRequired: Bool
    let busy: Bool
    let paused: String?
    let applicationResult: String
    let observedAt: String
    let availableModes: [Mode]
    // Optional for compatibility with older installed backends. Nil is unknown,
    // not a claim that the metadata snapshot was complete.
    var agentScanLimited: Bool? = nil
}

extension GlowMode {
    var externalName: String { self == .touch ? "trackpad" : rawValue }
}

enum MCPSetup {
    static func command(claude: Bool) -> String {
        let prefix = claude ? "claude mcp add --transport stdio --scope user backlit -- " : "codex mcp add backlit -- "
        return prefix + "/Applications/Backlit.app/Contents/MacOS/Backlit --mcp"
    }
}
