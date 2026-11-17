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
