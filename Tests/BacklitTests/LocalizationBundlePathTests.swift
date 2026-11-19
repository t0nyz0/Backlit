import Foundation
import XCTest
@testable import Backlit

final class LocalizationBundlePathTests: XCTestCase {
    func testCanonicalAndNormalizedLanguageDirectoriesLoadRealTables() throws {
        for nested in [false, true] {
            for lowercase in [false, true] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
                defer { try? FileManager.default.removeItem(at: root) }
                let resources = nested ? root.appendingPathComponent("Contents/Resources") : root
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                let info = nested ? root.appendingPathComponent("Contents/Info.plist") : root.appendingPathComponent("Info.plist")
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "fixture.backlit." + UUID().uuidString,
                    "CFBundleDevelopmentRegion": "en", "CFBundlePackageType": "BNDL"], format: .xml, options: 0).write(to: info)
                for language in AppLanguage.allCases {
                    let code = lowercase ? language.rawValue.lowercased() : language.rawValue
                    let directory = resources.appendingPathComponent(code + ".lproj")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let values = ["Settings": "translated-" + language.rawValue]
                    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                        .write(to: directory.appendingPathComponent("Localizable.strings"))
                }
                let bundle = try XCTUnwrap(Bundle(url: root))
                for language in AppLanguage.allCases {
                    let localized = try XCTUnwrap(LocalizationCatalogs.languageBundle(language, in: bundle), language.rawValue)
                    XCTAssertEqual(localized.localizedString(forKey: "Settings", value: nil, table: "Localizable"), "translated-" + language.rawValue)
                    let url = try XCTUnwrap(localized.url(forResource: "Localizable", withExtension: "strings"))
                    let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
                    XCTAssertEqual(table["Settings"], "translated-" + language.rawValue)
                }
            }
        }
    }

    func testAmbiguousCaseVariantsAreRejectedWithoutChoosingOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("pt-br.lproj")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let language = try XCTUnwrap(AppLanguage(rawValue: "pt-BR"))
        // Supply the enumeration boundary explicitly: a case-insensitive host
        // cannot create both spellings as distinct directories. Two matching
        // entries must fail closed, even when they alias on this filesystem.
        XCTAssertNil(LocalizationCatalogs.languageBundle(language, directories: [directory, directory]))
        let uppercase = root.appendingPathComponent("pt-BR.lproj")
        if FileManager.default.fileExists(atPath: uppercase.path) {
            XCTAssertNil(LocalizationCatalogs.languageBundle(language, directories: [directory, uppercase]))
        }
    }

    func testMissingLanguageDoesNotSelectAnotherLocale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertNil(LocalizationCatalogs.languageBundle(.english, in: bundle))
    }
}
