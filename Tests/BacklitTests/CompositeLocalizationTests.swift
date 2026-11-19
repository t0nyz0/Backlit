import XCTest
@testable import Backlit

@MainActor final class CompositeLocalizationTests: XCTestCase {
    func testBothActualRestorationFailuresRemainSeparateForLocalizedPresentation() throws {
        let suite = "local.backlit.test.composite." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(demo: true, defaults: defaults)
        var attempts: [String] = []
        let logo = "Could not restore the real logo lid state. Recovery is retained."
        let power = "Could not restore normal lid sleep."
        do {
            try LidRecovery(needsRestore: true, logoOverride: true).restore(
                logo: { attempts.append("logo"); throw RuntimeServices.failure(logo) },
                power: { attempts.append("power"); throw RuntimeServices.failure(power) })
            XCTFail("Both failures must remain reported")
        } catch {
            XCTAssertEqual(attempts, ["logo", "power"])
            XCTAssertEqual(error.localizedDescription, logo + " " + power)
            model.presentFailure(error)
            for language in AppLanguage.allCases {
                model.language = language.rawValue
                XCTAssertEqual(model.error, logo + " " + power)
                XCTAssertEqual(model.localizedError, model.l(logo) + " " + model.l(power))
                if language != .english { XCTAssertNotEqual(model.localizedError, model.error) }
            }
        }
        XCTAssertTrue(model.prepareQuit())
    }
    func testExternalDiagnosticPayloadIsNeverParsedOrTranslatedInsideGroup() {
        let payload = "Off\nMusic {detail} 日本語"
        let external = NSError(domain: "ExternalProvider", code: 7, userInfo: [NSLocalizedDescriptionKey: payload])
        let group = DisplayFailureGroup(failures: [RuntimeServices.failure("Could not restore normal lid sleep."), external], separator: "\n")
        for language in AppLanguage.allCases {
            XCTAssertTrue(group.render(language: language).hasSuffix(payload))
            XCTAssertEqual(group.localizedDescription, "Could not restore normal lid sleep.\n" + payload)
        }
    }
    func testBridgeSetupMessagesTranslateIndividuallyWithoutSplittingPayloads() throws {
        let messages = ["The MCP connection was switched off because its Keychain key is unavailable. Enable it again in Connections.", "Home Assistant was switched off because its Keychain key is unavailable. Enable it again in Connections."]
        let setup = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .status, intent: .automaticResume,
            readToken: { _, _, _ in throw NSError(domain: "inert-denied", code: 1) })
        XCTAssertEqual(setup.errors, messages)
        XCTAssertFalse(setup.homeAssistantEnabled)
        XCTAssertEqual(setup.agentAccess, .off)
        let group = DisplayFailureGroup(failures: setup.errors.map(RuntimeServices.failure), separator: "\n")
        for language in AppLanguage.allCases where language != .english {
            XCTAssertEqual(group.render(language: language), messages.map { Localization.text($0, language: language) }.joined(separator: "\n"))
            XCTAssertFalse(group.render(language: language).contains(messages[0]))
            XCTAssertFalse(group.render(language: language).contains(messages[1]))
        }
    }
}
