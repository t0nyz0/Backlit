import Foundation

/// Retry a denied start only when access changes, never on every render frame.
struct TypingStartPolicy {
    enum Action: Equatable { case start, stop, none }
    private var wanted = false
    private var allowed = false
    private var nextPermissionCheck = -Double.infinity

    mutating func action(eligible: Bool, force: Bool, now: Double,
                         permission: () -> Bool) -> Action {
        guard eligible else {
            wanted = false; allowed = false; nextPermissionCheck = -Double.infinity
            return .stop
        }
        let first = !wanted
        wanted = true
        guard first || force || now >= nextPermissionCheck else { return .none }
        nextPermissionCheck = now + 1
        let previous = allowed
        allowed = permission()
        if previous && !allowed { return .stop }
        return first || force || (!previous && allowed) ? .start : .none
    }
}

/// Inert driver injection for model-level lifecycle tests; production uses TypingInput.
struct TypingDriver {
    var eligible: () -> Bool
    var permission: () -> Bool
    var running: () -> Bool
    var start: () -> Bool
    var stop: () -> Void
    var now: () -> Double
}
