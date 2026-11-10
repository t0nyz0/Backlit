/// Do not redraw UI that the active user cannot see. Hardware effects and
/// their timing remain governed by the separate runtime safety policy.
enum VisualUpdatePolicy {
    static func allows(locked: Bool, screenSleeping: Bool, systemSleeping: Bool, consoleActive: Bool) -> Bool {
        !locked && !screenSleeping && !systemSleeping && consoleActive
    }
}
