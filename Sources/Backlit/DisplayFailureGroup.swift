import Foundation

/// Retains separate failure identities for presentation; machine-facing descriptions
/// keep the same English text and separator as before. Never split opaque error text.
struct DisplayFailureGroup: LocalizedError, CustomNSError {
    static var errorDomain: String { "Backlit" }
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? ""] }
    let failures: [Error]
    let separator: String
    var errorDescription: String? { failures.map { $0.localizedDescription }.joined(separator: separator) }
    func render(language: AppLanguage) -> String {
        failures.map { failure in
            if let group = failure as? DisplayFailureGroup { return group.render(language: language) }
            let native = failure as NSError
            // Only errors authored by this app are localizable. OS/third-party
            // diagnostics, including strings that happen to equal UI keys, stay exact.
            guard native.domain == "Backlit" || native.domain.hasPrefix("Backlit.") else { return failure.localizedDescription }
            return Localization.text(failure.localizedDescription, language: language)
        }.joined(separator: separator)
    }
}
