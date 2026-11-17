import Foundation

/// One presentation/protocol projection of the observed session snapshot.
/// Counts and aggregate state describe only the observed events when incomplete.
struct AgentSessionStatus {
    let observedCount: Int
    let observedState: AgentState
    let incomplete: Bool

    init(events: [AgentEvent], incomplete: Bool) {
        observedCount = events.count
        observedState = AgentBridge.aggregate(events)
        self.incomplete = incomplete
    }
    var warning: String? {
        incomplete ? "Session metadata is incomplete. Some coding sessions may be missing from this snapshot." : nil
    }
    private var incompleteSummary: String? {
        guard incomplete else { return nil }
        guard observedCount > 0 else { return "Session snapshot incomplete" }
        let noun = observedCount == 1 ? "session" : "sessions"
        return "\(observedCount) observed \(noun) · \(observedState.rawValue)"
    }
    var menuSummary: String {
        incompleteSummary ?? (observedCount == 0 ? "Waiting for an agent" : observedState.rawValue.capitalized)
    }
    var workspaceSummary: String {
        incompleteSummary ?? (observedCount == 0 ? "Waiting for an agent" : "\(observedCount) sessions · \(observedState.rawValue)")
    }
    var apiStateName: String {
        observedCount == 0 ? (incomplete ? "scan_limited" : "no_recent_signals") : observedState.rawValue
    }
}
