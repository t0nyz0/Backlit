import Foundation

/// Typed presentation messages keep opaque diagnostics and application names out of
/// translation matching. Associated values are inserted only after native lookup.
enum AppDisplayError {
    case listenerFailed(detail: String)
    case aiKeyReplacementFailed(detail: String)
    case competingApp(app: String)
    case pairingKeyReplacementFailed(detail: String)

    var template: String {
        switch self {
        case .listenerFailed: "Local connections were switched off because the listener failed. {detail}"
        case .aiKeyReplacementFailed: "AI access remains off because its key could not be replaced. {detail}"
        case .competingApp: "Quit {app} before changing logo settings."
        case .pairingKeyReplacementFailed: "A new pairing key could not be created, so Home Assistant sharing was switched off. Choose New Pairing Key again before switching it back on. ({detail})"
        }
    }
    var arguments: [String: String] {
        switch self {
        case .listenerFailed(let detail), .aiKeyReplacementFailed(let detail), .pairingKeyReplacementFailed(let detail): ["detail": detail]
        case .competingApp(let app): ["app": app]
        }
    }
    func render(language: AppLanguage) -> String {
        Localization.format(Localization.text(template, language: language), arguments: arguments)
    }
}
