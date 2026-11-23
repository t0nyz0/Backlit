import Foundation

/// Explicit HA setup may create/authorize its key. Automatic restoration and
/// unrelated MCP changes only reuse existing credentials without UI interaction.
enum BridgeCredentialIntent {
    case deliberateSetup, automaticResume
    var mayAuthorizeHomeAssistant: Bool { self == .deliberateSetup }
}

struct BridgeConnectionSetup {
    typealias TokenReader = (_ account: String, _ create: Bool, _ interactive: Bool) throws -> String
    let homeAssistantEnabled: Bool
    let agentAccess: MCPAccess
    let homeToken: String?
    let agentToken: String?
    let errors: [String]

    static func prepare(homeAssistantRequested: Bool, agentAccess: MCPAccess,
                        intent: BridgeCredentialIntent,
                        readToken: TokenReader = { try BridgeToken.value(account: $0, create: $1, interactive: $2) }) throws -> Self {
        var access = agentAccess
        var agentToken: String?
        var errors: [String] = []
        if access != .off {
            do { agentToken = try readToken(BridgeToken.agentAccount, false, false) }
            catch {
                access = .off
                errors.append("The MCP connection was switched off because its Keychain key is unavailable. Enable it again in Connections.")
            }
        }
        var homeEnabled = homeAssistantRequested
        var homeToken: String?
        if homeAssistantRequested {
            do {
                let authorize = intent.mayAuthorizeHomeAssistant
                homeToken = try readToken(BridgeToken.account, authorize, authorize)
            } catch {
                homeEnabled = false
                errors.append("Home Assistant was switched off because its Keychain key is unavailable. Enable it again in Connections.")
            }
        }
        return Self(homeAssistantEnabled: homeEnabled, agentAccess: access,
                    homeToken: homeToken, agentToken: agentToken, errors: errors)
    }

    /// One production-used admission point: no listener when both scopes failed,
    /// and a surviving MCP-only listener can never inherit the HA LAN preference.
    @discardableResult func start(lan requestedLAN: Bool,
                                 using start: (Bool, String?, String?, MCPAccess) throws -> Void) throws -> Bool {
        guard homeAssistantEnabled || agentAccess != .off else { return false }
        try start(homeAssistantEnabled && requestedLAN, homeToken, agentToken, agentAccess)
        return true
    }
}


/// Apply only the last still-authorized startup read. No Keychain work runs on
/// the main queue, and a delayed read cannot reopen a listener after a setting
/// change or the app's approved quit.
@MainActor final class BridgeStartupResume {
    typealias Prepare = @Sendable (_ enabled: Bool, _ access: MCPAccess) throws -> BridgeConnectionSetup
    private var generation = UUID()
    private var pendingLAN: Bool?

    var isPending: Bool { pendingLAN != nil }

    func begin(enabled: Bool, access: MCPAccess, lan: Bool,
               prepare: @escaping Prepare = { try BridgeConnectionSetup.prepare(
                   homeAssistantRequested: $0, agentAccess: $1, intent: .automaticResume) },
               complete: @escaping @MainActor (Result<BridgeConnectionSetup, Error>, Bool) -> Void) {
        let request = UUID()
        generation = request
        pendingLAN = lan
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try prepare(enabled, access) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, let lan = self.pendingLAN else { return }
                self.pendingLAN = nil
                complete(result, lan)
            }
        }
    }

    /// LAN scope does not change credential authorization. Keep the in-flight
    /// read and apply only the latest scope if its credentials are still valid.
    func updateLAN(_ lan: Bool) -> Bool {
        guard isPending else { return false }
        pendingLAN = lan
        return true
    }

    func invalidate() { generation = UUID(); pendingLAN = nil }
}
