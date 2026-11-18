import XCTest
@testable import Backlit

final class AppDisplayErrorTests: XCTestCase {
    func testActionableErrorsAreTranslatedWithoutTranslatingOpaqueArguments() {
        let opaque = "Music {detail} 日本語\nOff"
        let messages: [AppDisplayError] = [.listenerFailed(detail: opaque), .aiKeyReplacementFailed(detail: opaque), .competingApp(app: opaque), .pairingKeyReplacementFailed(detail: opaque)]
        for message in messages {
            for language in AppLanguage.allCases {
                XCTAssertEqual(Localization.placeholders(in: message.template), Set(message.arguments.keys))
                XCTAssertTrue(message.render(language: language).contains(opaque), language.rawValue)
                if language != .english {
                    XCTAssertNotEqual(message.render(language: language), message.render(language: .english), "\(language.rawValue): \(message.template)")
                }
            }
        }
    }
}

@MainActor final class AppDisplayErrorPresentationTests: XCTestCase {
    func testTypedErrorTracksLanguageAndClearsWhenReplacedByRawDiagnostic() {
        let name = "local.backlit.tests.messages." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(demo: true, defaults: defaults)
        model.language = "fr"
        let message = AppDisplayError.listenerFailed(detail: "Music")
        model.presentError(message)
        XCTAssertEqual(model.error, message.render(language: .english))
        XCTAssertEqual(model.localizedError, message.render(language: .french))
        model.language = "ja"
        XCTAssertEqual(model.localizedError, message.render(language: .japanese))
        model.error = "opaque.machine.diagnostic"
        XCTAssertEqual(model.localizedError, "opaque.machine.diagnostic")
        model.error = nil
        XCTAssertEqual(model.localizedError, "")
        XCTAssertTrue(model.prepareQuit())
    }
}
