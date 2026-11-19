import Foundation

/// Pure projection of the current frame's observed safety state. The caller still
/// obtains all native observations and performs cleanup; this function cannot
/// start hardware or change system settings. Keep the precedence intentional.
enum FramePausePolicy {
    static func message(systemSleeping: Bool, competingController: String?, consoleActive: Bool,
                        criticalThermal: Bool, liveHardware: Bool, mode: GlowMode, allowClosed: Bool,
                        screenSleeping: Bool, locked: Bool, lowPower: Bool) -> String? {
        if systemSleeping { return "Mac is sleeping" }
        if let competingController { return "Quit \(competingController) to use Backlit" }
        if !consoleActive { return "User session inactive" }
        if criticalThermal { return "Paused while your Mac cools down" }
        if liveHardware && mode != .agents && !allowClosed && (screenSleeping || locked) { return "Paused with your display" }
        if liveHardware && lowPower && mode != .agents && mode != .battery { return "Paused in Low Power Mode" }
        return nil
    }
}
