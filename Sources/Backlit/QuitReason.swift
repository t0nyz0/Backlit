import AppKit
import Carbon

/// Only an explicit system session-end reason skips the Off-logo warning.
/// Missing or unknown reasons keep normal Quit consent, including CLI/update quits.
enum QuitReason: Equatable {
    case userInitiated
    case systemSessionEnd

    init(appleEvent: NSAppleEventDescriptor?) {
        guard let appleEvent,
              appleEvent.eventClass == AEEventClass(kCoreEventClass),
              appleEvent.eventID == AEEventID(kAEQuitApplication),
              let reason = appleEvent.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else {
            self = .userInitiated
            return
        }
        // AERegistry.h documents these session-end values for kAEQuitReason.
        // kAEQuitAll is deliberately excluded: quitting apps alone is not logout.
        switch reason.enumCodeValue {
        case OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut):
            self = .systemSessionEnd
        default:
            self = .userInitiated
        }
    }

    var requiresOffConfirmation: Bool { self == .userInitiated }
}
