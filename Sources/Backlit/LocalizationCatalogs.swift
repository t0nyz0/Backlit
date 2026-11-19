import Foundation

/// Xcode .xcstrings catalogs are the source of truth. SwiftPM packages Apple's compiled
/// .strings files; explicit lproj bundles support Backlit's in-app language override.
enum LocalizationCatalogs {
    static let resourceBundle: Bundle = {
        // The standalone app packager puts the SwiftPM bundle under Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Backlit_Backlit.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        #if BACKLIT_STANDALONE
        // Never embed SwiftPM's development-machine fallback path in a release.
        // Packaged resources are mandatory; missing resources must not silently
        // fall back to the build checkout.
        fatalError("Missing packaged localization resources.")
        #else
        return Bundle.module
        #endif
    }()
    // SwiftPM versions differ in whether script/region directory names are
    // preserved (zh-Hant) or normalized (zh-hant). Resolve the actual resource
    // URL without changing the canonical language preference or translated text.
    static func languageBundle(_ language: AppLanguage, in resources: Bundle) -> Bundle? {
        guard let root = resources.resourceURL,
              let entries = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return languageBundle(language, directories: entries)
    }
    static func languageBundle(_ language: AppLanguage, directories: [URL]) -> Bundle? {
        let matches = directories.filter {
            $0.lastPathComponent.caseInsensitiveCompare(language.rawValue + ".lproj") == .orderedSame
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard matches.count == 1 else { return nil }
        return Bundle(url: matches[0])
    }
    private static let languageBundles: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.compactMap { language in
            guard let bundle = languageBundle(language, in: resourceBundle) else { return nil }
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
