import Foundation

/// Xcode .xcstrings catalogs are the source of truth. SwiftPM packages Apple's compiled
/// .strings files; explicit lproj bundles support Backlit's in-app language override.
enum LocalizationCatalogs {
    static let resourceBundle: Bundle = {
        // The standalone app packager puts the SwiftPM bundle under Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Backlit_Backlit.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()
    private static let languageBundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            guard let url = resourceBundle.url(forResource: language.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else { return nil }
            return (language.rawValue, bundle)
        })
    static func localizedString(_ key: String, language: AppLanguage) -> String {
        guard let bundle = languageBundles[language.rawValue] else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    /// Read-only compatibility index for template enumeration and completeness tests.
    /// Presentation should use localizedString so lookup follows Foundation's resource API.
    static let translations: [String: [String: String]] = Dictionary(uniqueKeysWithValues:
        languageBundles.map { language, bundle in
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
                  let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            else { return (language, [:]) }
            return (language, values)
        })
    static let sourceKeys: Set<String> = Set(translations["en"]?.keys.map { $0 } ?? [])
}
