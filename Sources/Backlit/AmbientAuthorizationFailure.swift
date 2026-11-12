import AppKit

/// Only AppleScript's explicit user-cancel result proves the helper did not run.
/// Other failures may follow partial work and must not trigger automatic resume.
enum AmbientAuthorizationFailure: LocalizedError {
    case cancelled
    case failed(String)

    init(scriptError: NSDictionary) {
        if (scriptError[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 {
            self = .cancelled
        } else {
            self = .failed(scriptError[NSAppleScript.errorMessage] as? String ??
                "The ambient brightness change could not be confirmed. Restore the saved limits before retrying.")
        }
    }
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Authorization was cancelled."
        case let .failed(message): return message
        }
    }
}
