import Foundation

/// Persist the user's choice separately from the language currently selected by macOS.
/// An explicit supported choice always wins; unknown saved choices use English.
enum AppLanguage: String, CaseIterable {
    case english = "en", spanish = "es", french = "fr", german = "de"
    case japanese = "ja", korean = "ko", portugueseBrazil = "pt-BR"
    case chineseSimplified = "zh-Hans", chineseTraditional = "zh-Hant", thai = "th"

    var nativeName: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .portugueseBrazil: "Português (Brasil)"
        case .chineseSimplified: "简体中文"
        case .chineseTraditional: "繁體中文"
        case .thai: "ไทย"
        }
    }
    private static var supportedIdentifiers: [String] { allCases.map(\.rawValue) }
    /// Foundation respects the current app's language preference as well as the
    /// system preference list. Never write AppleLanguages or change system settings.
    static var systemPreferredLanguages: [String] {
        Bundle.preferredLocalizations(from: supportedIdentifiers)
    }
    static func resolve(preference: String, preferredLanguages: [String]) -> AppLanguage {
        if preference != "system" { return AppLanguage(rawValue: preference) ?? .english }
        let normalized = preferredLanguages.map { $0.replacingOccurrences(of: "_", with: "-") }
        return Bundle.preferredLocalizations(from: supportedIdentifiers, forPreferences: normalized)
            .compactMap(AppLanguage.init(rawValue:)).first ?? .english
    }
}

/// English source keys are shared by every language. Unknown text remains readable
/// English. Only presentation uses this layer; protocol fields and state stay stable.
enum Localization {
    static func text(_ english: String, language: AppLanguage, traditionalChinese: String? = nil) -> String {
        if language == .english { return english }
        let catalog = LocalizationCatalogs.translations[language.rawValue] ?? [:]
        if catalog[english] != nil { return LocalizationCatalogs.localizedString(english, language: language) }
        if language == .chineseTraditional, let traditionalChinese { return traditionalChinese }
        // One shared template mechanism for runtime messages, not language-specific
        // regular expressions. Literal text is always escaped before matching.
        for template in templates[language] ?? [] {
            guard let arguments = template.match(english) else { continue }
            let key = template.key
            // Translate only exact known fragments, never recurse through arbitrary
            // user-provided names, URLs, error strings, or other templates.
            let semanticSlots: Set<String> = ["state", "mode", "source"]
            let localizedArguments = arguments.map { key, value in
                (key, semanticSlots.contains(key) ? (catalog[value] ?? value) : value)
            }
            return format(LocalizationCatalogs.localizedString(key, language: language), arguments: Dictionary(uniqueKeysWithValues: localizedArguments))
        }
        return english
    }
    static func format(_ template: String, arguments: [String: String]) -> String {
        let tokens = placeholderRanges(template)
        var result = template
        for token in tokens.reversed() {
            guard let range = Range(token.range, in: result), let value = arguments[token.name] else { continue }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
    static func placeholders(in template: String) -> Set<String> { Set(placeholderRanges(template).map(\.name)) }
    private static func placeholderRanges(_ text: String) -> [(range: NSRange, name: String)] {
        guard let expression = try? NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let name = Range(match.range(at: 1), in: text) else { return nil }
            return (match.range, String(text[name]))
        }
    }
    private static let templates: [AppLanguage:[MessageTemplate]] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.map { language in
            (language, (LocalizationCatalogs.translations[language.rawValue] ?? [:]).keys.sorted().compactMap(MessageTemplate.init))
        })
    static func match(template: String, text: String) -> [String:String]? {
        MessageTemplate(template)?.match(text)
    }
    /// Compile the finite catalog once, rather than constructing regular expressions
    /// every time a live brightness/status view redraws.
    private struct MessageTemplate {
        let key: String
        let tokens: [(range: NSRange, name: String)]
        let expression: NSRegularExpression
        init?(_ template: String) {
            let tokens = placeholderRanges(template)
            guard !tokens.isEmpty else { return nil }
            let ns = template as NSString
            var cursor = 0, pattern = "^"
            for token in tokens {
                pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))) + "(.+?)"
                cursor = NSMaxRange(token.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: cursor)) + "$"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            self.key = template; self.tokens = tokens; self.expression = expression
        }
        func match(_ text: String) -> [String:String]? {
            guard let result = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            var arguments: [String:String] = [:]
            for (index, token) in tokens.enumerated() {
                guard let range = Range(result.range(at: index + 1), in: text) else { return nil }
                let value = String(text[range])
                if let previous = arguments[token.name], previous != value { return nil }
                arguments[token.name] = value
            }
            return arguments
        }
    }
}
