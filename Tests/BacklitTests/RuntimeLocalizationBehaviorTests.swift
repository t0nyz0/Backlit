import XCTest
@testable import Backlit

/// These fixtures obtain messages from production emitters/policies. They never
/// listen for keys, open sockets, alter power settings, or acquire the logo.
@MainActor final class RuntimeLocalizationBehaviorTests: XCTestCase {
    private func withModel(_ body: (AppModel) throws -> Void) rethrows {
        let suite = "local.backlit.runtime-localization." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(demo: true, defaults: defaults, preferredLanguages: { ["en-US"] })
        defer { _ = model.prepareQuit(); defaults.removePersistentDomain(forName: suite) }
        try body(model)
    }
    private func assertLocalized(_ english: String, model: AppModel,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(english.isEmpty, file: file, line: line)
        model.language = "en"
        XCTAssertEqual(model.l(english), english, file: file, line: line)
        for language in AppLanguage.allCases where language != .english {
            model.language = language.rawValue
            let rendered = model.l(english)
            XCTAssertFalse(rendered.isEmpty, language.rawValue, file: file, line: line)
            XCTAssertNotEqual(rendered, english, "\(language.rawValue): \(english)", file: file, line: line)
        }
    }
    func testActualShortcutConflictRendersInEveryLanguageWithoutChangingStoredIssue() throws {
        try withModel { model in
            let binding = try XCTUnwrap(model.logoShortcuts[.toggle])
            XCTAssertFalse(model.setLogoShortcut(binding, action: .decrease))
            let emitted = try XCTUnwrap(model.shortcutIssues[.decrease])
            assertLocalized(emitted, model: model)
            XCTAssertEqual(model.shortcutIssues[.decrease], emitted)
            XCTAssertNil(model.logoShortcuts[.decrease])
        }
    }
    func testTypingPermissionEmittersAndSuccessfulReadyTextWithoutNativeTap() {
        withModel { model in
            var requests = 0
            let denied = TypingInput(preflightAccess: { false }, requestAccess: { requests += 1; return false })
            XCTAssertFalse(denied.start(), "Denied preflight returns before creating a native event tap")
            assertLocalized(denied.status, model: model)
            let check = denied.requestPermissionCheck()
            XCTAssertEqual(requests, 1); XCTAssertFalse(check.after)
            assertLocalized(denied.status, model: model)
            XCTAssertFalse(denied.running)
            let allowed = TypingInput(preflightAccess: { true }, requestAccess: {
                XCTFail("Already allowed access must not prompt"); return false
            })
            XCTAssertTrue(allowed.requestPermissionCheck().after)
            assertLocalized(allowed.status, model: model)
            XCTAssertFalse(allowed.running, "Permission check does not start listening")
            // The actual successful-start path emits this exact shared value. Its
            // wiring is asserted below; the native listener is deliberately not run.
            assertLocalized(TypingInput.readyStatus, model: model)
        }
    }
    func testActualBridgeReadyProjectionRendersBothScopesWithoutNetwork() {
        withModel { model in
            for lan in [false, true] {
                let emitted = HomeBridge.readyStatus(lan: lan)
                assertLocalized(emitted, model: model)
                XCTAssertEqual(HomeBridge.readyStatus(lan: lan), emitted)
            }
        }
    }
    private func pause(sleeping: Bool = false, controller: String? = nil, active: Bool = true,
                       hot: Bool = false, live: Bool = true, mode: GlowMode = .steady,
                       allowClosed: Bool = false, screen: Bool = false, locked: Bool = false,
                       lowPower: Bool = false) -> String? {
        FramePausePolicy.message(systemSleeping: sleeping, competingController: controller,
            consoleActive: active, criticalThermal: hot, liveHardware: live, mode: mode,
            allowClosed: allowClosed, screenSleeping: screen, locked: locked, lowPower: lowPower)
    }
    func testActualPausePolicyLocalizesWithoutChangingSafetyPrecedence() throws {
        try withModel { model in
            for emitted in [pause(sleeping:true), pause(active:false), pause(hot:true),
                            pause(screen:true), pause(locked:true), pause(lowPower:true)] {
                assertLocalized(try XCTUnwrap(emitted), model: model)
            }
            XCTAssertEqual(pause(sleeping:true, controller:"OpaqueApp", active:false, hot:true, screen:true, lowPower:true), pause(sleeping:true))
            XCTAssertEqual(pause(controller:"OpaqueApp", active:false, hot:true, lowPower:true), pause(controller:"OpaqueApp"))
            XCTAssertEqual(pause(active:false, hot:true, screen:true, lowPower:true), pause(active:false))
            XCTAssertEqual(pause(hot:true, screen:true, lowPower:true), pause(hot:true))
            XCTAssertEqual(pause(screen:true, lowPower:true), pause(screen:true))
            XCTAssertNil(pause(lowPower:false)); XCTAssertNil(pause(live:false, lowPower:true))
            XCTAssertNil(pause(mode:.agents, screen:true, lowPower:true))
            XCTAssertNil(pause(mode:.battery, lowPower:true))
            XCTAssertNil(pause(allowClosed:true, screen:true))
            XCTAssertEqual(pause(allowClosed:true, screen:true, lowPower:true), pause(lowPower:true))
            let opaque = "Vendor Ω (pt-BR) 7.2"
            let emitted = try XCTUnwrap(pause(controller:opaque))
            assertLocalized(emitted, model:model)
            for language in AppLanguage.allCases {
                model.language = language.rawValue
                XCTAssertTrue(model.l(emitted).contains(opaque), language.rawValue)
            }
        }
    }
    func testActualAudioRecoveryAndUpdateFailuresLocalizeWithoutChangingDiagnostics() {
        withModel { model in
            var emitted = [FadeSessionInterruption.lifecycle.localizedDescription,
                           FadeSessionInterruption.sourceMode.localizedDescription]
            emitted.append(SystemAudio.friendly(NSError(domain:"fixture.audio",code:-3801)).localizedDescription)
            for preview in [false,true] {
                do { _ = try UpdateConfiguration(info:[:],preview:preview); XCTFail("Invalid config accepted") }
                catch { emitted.append(error.localizedDescription) }
            }
            do { try UpdateConfiguration.validateAsset(nil,build:"2",current:"1",architecture:"arm64"); XCTFail("Invalid asset accepted") }
            catch { emitted.append(error.localizedDescription) }
            for text in emitted { assertLocalized(text, model:model) }
            let detail = "Driver_X Ω / error -9271; region=pt-BR; https://example.invalid/a?x=1"
            let native = NSError(domain:"opaque.vendor",code:42,userInfo:[NSLocalizedDescriptionKey:detail])
            XCTAssertEqual(SystemAudio.friendly(native).localizedDescription, detail)
            let recovery = FadeSessionInterruption.outputTimeout(detail)
            for language in AppLanguage.allCases {
                model.language = language.rawValue
                XCTAssertEqual(model.l(native.localizedDescription),detail)
                XCTAssertEqual(model.l(recovery.localizedDescription),detail)
            }
        }
    }
    func testActualNativeAudioStageDescriptionsPreserveCodesAndLocalizeSentence() {
        guard #available(macOS 14.2, *) else { return }
        let stages = ["request system audio", "read the audio format", "prepare system audio", "connect system audio", "start system audio"]
        withModel { model in
            for stage in stages {
                let english = ProcessAudioTap.failureDescription(status: -50, stage: stage)
                assertLocalized(english, model: model)
                for language in AppLanguage.allCases {
                    model.language = language.rawValue
                    XCTAssertTrue(model.l(english).contains("-50"))
                }
            }
            let opaque = ProcessAudioTap.failureDescription(status: -27, stage: "opaque Driver_X")
            XCTAssertEqual(Localization.text(opaque, language: .thai), opaque)
        }
    }
    func testPurePoliciesAreWiredToActualRuntimeEmitters() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func source(_ name:String) throws -> String {
            try String(contentsOf:root.appendingPathComponent("Sources/Backlit/"+name),encoding:.utf8)
        }
        let model = try source("AppModel.swift")
        XCTAssertTrue(model.contains("let nextPause = FramePausePolicy.message(systemSleeping: systemSleeping"))
        XCTAssertTrue(model.contains("locked: cachedLocked, lowPower: lowPower)"))
        XCTAssertTrue(model.contains("let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled"))
        XCTAssertTrue(try source("HomeBridge.swift").contains("case .ready: self?.onStatus?(Self.readyStatus(lan: lan))"))
        XCTAssertTrue(try source("TypingInput.swift").contains("status=Self.readyStatus"))
    }
}
