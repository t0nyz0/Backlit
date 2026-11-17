import XCTest
import AppKit
import Carbon
@testable import Backlit

@MainActor final class GlobalShortcutTests: XCTestCase {
    private var bindings: [LogoShortcutAction:LogoShortcut] {
        Dictionary(uniqueKeysWithValues:LogoShortcutAction.allCases.map{($0,$0.legacyDefaultBinding)})
    }
    private final class Backend {
        var next = 0
        var failedKey: UInt32?
        var registered: [Int:LogoShortcut] = [:]
        var removed: [Int] = []
        func register(_ action: LogoShortcutAction, _ binding: LogoShortcut) throws -> Int {
            if failedKey == binding.keyCode { throw ShortcutError(message:"Fixture conflict") }
            next += 1; registered[next] = binding; return next
        }
        func unregister(_ reference: Int) { removed.append(reference); registered.removeValue(forKey:reference) }
    }
    private func registry() -> (LogoShortcutRegistry<Int>,Backend) {
        let backend = Backend()
        return (LogoShortcutRegistry(register:backend.register,unregister:backend.unregister),backend)
    }
    private func model(_ body: (AppModel,UserDefaults) throws -> Void) rethrows {
        let suite = "local.backlit.shortcuts." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defaults.set("steady",forKey:"mode")
        let model = AppModel(demo:true,defaults:defaults)
        defer { _ = model.prepareQuit(); defaults.removePersistentDomain(forName:suite) }
        try body(model,defaults)
    }
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags, characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,
            context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    func testFreshInstallAndResetUseToggleOnly() {
        model { model, defaults in
            XCTAssertEqual(model.logoShortcuts[.toggle]?.label,"⌃⌘B")
            XCTAssertNil(model.logoShortcuts[.decrease]); XCTAssertNil(model.logoShortcuts[.increase])
            XCTAssertEqual(LogoShortcutPreferences.load(defaults),model.logoShortcuts)
            let relaunched = AppModel(demo:true,defaults:defaults)
            XCTAssertEqual(relaunched.logoShortcuts,model.logoShortcuts)
            _ = relaunched.prepareQuit()
            for action in [LogoShortcutAction.decrease, .increase] {
                XCTAssertTrue(model.setLogoShortcut(action.legacyDefaultBinding,action:action))
                XCTAssertTrue(model.setLogoShortcut(action.defaultBinding,action:action))
                XCTAssertNil(LogoShortcutPreferences.load(defaults)[action])
            }
            XCTAssertEqual(LogoShortcutAction.toggle.defaultBinding?.label,"⌃⌘B")
        }
    }
    func testExistingImplicitShortcutsMigrateOnceWithoutChangingSavedChoices() throws {
        let suite = "local.backlit.shortcut-migration." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set("existing-install",forKey:"installation.id")
        defaults.set("untouched",forKey:"unrelated")
        let custom = LogoShortcut(keyCode:45,modifiers:4352,keyLabel:"N")
        try LogoShortcutPreferences.save(custom,action:.toggle,defaults:defaults)
        try LogoShortcutPreferences.save(nil,action:.decrease,defaults:defaults)
        let first = LogoShortcutPreferences.load(defaults)
        XCTAssertEqual(first[.toggle],custom); XCTAssertNil(first[.decrease])
        XCTAssertEqual(first[.increase],LogoShortcutAction.increase.legacyDefaultBinding)
        XCTAssertEqual(defaults.string(forKey:"unrelated"),"untouched")
        XCTAssertEqual(LogoShortcutPreferences.load(defaults),first)
        try LogoShortcutPreferences.save(LogoShortcutAction.increase.defaultBinding,action:.increase,defaults:defaults)
        XCTAssertNil(LogoShortcutPreferences.load(defaults)[.increase])
        try LogoShortcutPreferences.save(custom,action:.increase,defaults:defaults)
        XCTAssertEqual(LogoShortcutPreferences.load(defaults)[.increase],custom)
    }
    func testRecorderNamesArrowsAndIgnoresCapsLockAndNumericPadFlags() throws {
        let binding = try LogoShortcut.capture(key(126,flags:[.command,.control,.capsLock,.numericPad,.function]))
        XCTAssertEqual(binding,.init(keyCode:126,modifiers:4352,keyLabel:"↑"))
    }
    func testShiftOnlyAndUnmodifiedChordsAreNotOrdinaryGlobalShortcuts() {
        for flags in [NSEvent.ModifierFlags.shift,[]] {
            XCTAssertThrowsError(try LogoShortcut.capture(key(122,flags:flags)))
            XCTAssertThrowsError(try LogoShortcut.capture(key(0,flags:flags,characters:"a")))
        }
        XCTAssertThrowsError(try LogoShortcut(keyCode:126,modifiers:4352 | 0x100000,keyLabel:"↑").validate())
        XCTAssertThrowsError(try LogoShortcut(keyCode:UInt32.max,modifiers:4352,keyLabel:"bad").validate())
    }
    func testLiteralFunctionKeyIsNotTreatedAsAMediaEvent() throws {
        XCTAssertEqual(try LogoShortcut.capture(key(122,flags:[.command,.control,.function])).label,"⌃⌘F1")
        let event = NSEvent.otherEvent(with:.systemDefined,location:.zero,modifierFlags:.shift,timestamp:0,
            windowNumber:0,context:nil,subtype:8,data1:(2 << 16) | (0x0a << 8),data2:0)!
        XCTAssertThrowsError(try LogoShortcut.capture(event))
    }
    func testLegacyTogglePreferenceMigratesWithoutChangingOtherPreferences() {
        model { _,defaults in
            defaults.set(45,forKey:"shortcut.key"); defaults.set(2304,forKey:"shortcut.modifiers")
            defaults.set("⌥⌘N",forKey:"shortcut.label"); defaults.set("keep",forKey:"unrelated")
            let loaded = LogoShortcutPreferences.load(defaults)
            XCTAssertEqual(loaded[.toggle]?.label,"⌥⌘N")
            XCTAssertEqual(loaded[.increase],LogoShortcutAction.increase.defaultBinding)
            XCTAssertEqual(defaults.string(forKey:"unrelated"),"keep")
        }
    }
    func testCorruptedLegacyAndNewPreferencesCannotCrashOrInstallBareKeys() {
        model { _,defaults in
            defaults.set(-1,forKey:"shortcut.key"); defaults.set(-1,forKey:"shortcut.modifiers")
            XCTAssertEqual(LogoShortcutPreferences.load(defaults)[.toggle],LogoShortcutAction.toggle.defaultBinding)
            defaults.set(Data(#"{"keyCode":0,"modifiers":0,"keyLabel":"A"}"#.utf8),forKey:LogoShortcutAction.increase.preferenceKey)
            XCTAssertEqual(LogoShortcutPreferences.load(defaults)[.increase],LogoShortcutAction.increase.defaultBinding)
        }
    }
    func testDisabledShortcutStaysDisabledAfterRelaunch() throws {
        try model { model,defaults in
            XCTAssertTrue(model.setLogoShortcut(nil,action:.increase))
            XCTAssertNil(LogoShortcutPreferences.load(defaults)[.increase])
            defaults.set(Data(" \nnull\n".utf8),forKey:LogoShortcutAction.increase.preferenceKey)
            XCTAssertNil(LogoShortcutPreferences.load(defaults)[.increase])
            XCTAssertEqual(LogoShortcutPreferences.load(defaults)[.toggle],LogoShortcutAction.toggle.defaultBinding)
            try LogoShortcutPreferences.save(.init(keyCode:45,modifiers:4352,keyLabel:"N"),action:.increase,defaults:defaults)
            XCTAssertEqual(LogoShortcutPreferences.load(defaults)[.increase]?.label,"⌃⌘N")
        }
    }
    func testFailedNativeReplacementKeepsPreviousRegistrationAndSettings() throws {
        let (registry,backend) = registry()
        XCTAssertTrue(registry.configure(bindings).isEmpty)
        backend.failedKey = 45
        XCTAssertThrowsError(try registry.replace(.init(keyCode:45,modifiers:4352,keyLabel:"N"),for:.increase))
        XCTAssertEqual(backend.registered.count,3); XCTAssertTrue(backend.removed.isEmpty)
        XCTAssertEqual(registry.desired[.increase],LogoShortcutAction.increase.legacyDefaultBinding)
        model { model,defaults in
            model.onShortcutChange = { _,_ in "Fixture conflict" }
            XCTAssertFalse(model.setLogoShortcut(.init(keyCode:45,modifiers:4352,keyLabel:"N"),action:.increase))
            XCTAssertNil(defaults.data(forKey:LogoShortcutAction.increase.preferenceKey))
            XCTAssertEqual(model.logoShortcuts[.increase],LogoShortcutAction.increase.defaultBinding)
        }
    }
    func testLocalDuplicateIsRejectedBeforeNativeRegistration() {
        model { model,_ in
            var calls = 0; model.onShortcutChange = { _,_ in calls += 1; return nil }
            XCTAssertFalse(model.setLogoShortcut(LogoShortcutAction.toggle.defaultBinding,action:.decrease))
            XCTAssertEqual(calls,0)
        }
    }
    func testSamePhysicalChordCanUpdateItsLabelWithoutConflictingWithItself() throws {
        let (registry,backend) = registry(); _ = registry.configure(bindings)
        try registry.replace(.init(keyCode:11,modifiers:4352,keyLabel:"New layout label"),for:.toggle)
        XCTAssertEqual(backend.next,3); XCTAssertTrue(backend.removed.isEmpty)
        XCTAssertEqual(registry.desired[.toggle]?.keyLabel,"New layout label")
    }
    func testEventIDsRouteOnlyToActiveRegisteredActions() {
        let (registry,_) = registry(); _ = registry.configure(bindings)
        for action in LogoShortcutAction.allCases {
            XCTAssertEqual(registry.action(signature:LogoShortcutAction.signature,id:action.rawValue),action)
        }
        XCTAssertNil(registry.action(signature:0,id:1)); XCTAssertNil(registry.action(signature:LogoShortcutAction.signature,id:99))
    }
    func testRecordingSuspendsActionsAndKeepsAReplacementForResume() throws {
        let (registry,backend) = registry(); _ = registry.configure(bindings)
        registry.suspend(); XCTAssertEqual(backend.registered.count,0)
        XCTAssertNil(registry.action(signature:LogoShortcutAction.signature,id:1))
        try registry.replace(.init(keyCode:45,modifiers:4352,keyLabel:"N"),for:.increase)
        XCTAssertNil(registry.action(signature:LogoShortcutAction.signature,id:3))
        XCTAssertTrue(registry.resume().isEmpty); XCTAssertEqual(backend.registered.count,3)
        XCTAssertEqual(registry.action(signature:LogoShortcutAction.signature,id:3),.increase)
        XCTAssertEqual(registry.desired[.increase]?.label,"⌃⌘N")
    }
    func testDuplicateSavedBindingsDoNotLoseTheExistingToggle() {
        let (registry,_) = registry(); var saved = bindings
        saved[.increase] = saved[.toggle]
        let issues = registry.configure(saved)
        XCTAssertNotNil(issues[.increase]); XCTAssertNil(issues[.toggle])
        XCTAssertEqual(registry.action(signature:LogoShortcutAction.signature,id:1),.toggle)
    }
    func testDisablingOneActionLeavesOtherRegistrationsUsable() throws {
        let (registry,backend) = registry(); _ = registry.configure(bindings)
        try registry.replace(nil,for:.increase)
        XCTAssertEqual(backend.registered.count,2)
        XCTAssertNil(registry.action(signature:LogoShortcutAction.signature,id:3))
        XCTAssertEqual(registry.action(signature:LogoShortcutAction.signature,id:1),.toggle)
    }
    func testResumeConflictIsReportedForOnlyTheAffectedAction() {
        let (registry,backend) = registry(); _ = registry.configure(bindings)
        registry.suspend(); backend.failedKey = 126
        let issues = registry.resume()
        XCTAssertNotNil(issues[.increase]); XCTAssertEqual(backend.registered.count,2)
        XCTAssertEqual(registry.action(signature:LogoShortcutAction.signature,id:2),.decrease)
        XCTAssertNil(registry.action(signature:LogoShortcutAction.signature,id:3))
    }
    func testFivePercentStepsClampAndPreserveFractionalLevels() {
        XCTAssertEqual(LogoBrightnessStep.next(0.375,action:.increase,mode:.steady)!,0.425,accuracy:0.000001)
        XCTAssertEqual(LogoBrightnessStep.next(0.375,action:.decrease,mode:.steady)!,0.325,accuracy:0.000001)
        XCTAssertEqual(LogoBrightnessStep.next(0.99,action:.increase,mode:.breathe),1)
        XCTAssertEqual(LogoBrightnessStep.next(0.01,action:.decrease,mode:.agents),0)
        XCTAssertNil(LogoBrightnessStep.next(.nan,action:.increase,mode:.steady))
        XCTAssertNil(LogoBrightnessStep.next(0.5,action:.toggle,mode:.steady))
    }
    func testBrightnessHotkeysKeepPowerAndBehaviorIncludingWhenOff() {
        model { model,defaults in
            for mode in GlowMode.allCases where mode != .battery {
                model.mode = mode; model.enabled = false; model.brightness = 0.4
                model.performLogoShortcut(.increase)
                XCTAssertEqual(model.brightness,0.45,accuracy:0.000001)
                XCTAssertFalse(model.enabled); XCTAssertEqual(model.mode,mode)
                XCTAssertEqual(defaults.double(forKey:"brightness"),0.45,accuracy:0.000001)
            }
        }
    }
    func testBatteryModeRemainsAutomaticAndDoesNotChangeSavedManualLevel() {
        model { model,_ in
            model.mode = .battery; model.brightness = 0.4
            model.performLogoShortcut(.increase); model.performLogoShortcut(.decrease)
            XCTAssertEqual(model.brightness,0.4); XCTAssertEqual(model.mode,.battery)
            XCTAssertTrue(model.notice?.contains("Battery") == true)
        }
    }
    func testBrightnessShortcutsDoNotMutateSettingsInsideHardwareRecovery() {
        model { model,_ in
            model.brightness = 0.4
            _ = model.withHardwareRecovery { model.performLogoShortcut(.increase) }
            XCTAssertEqual(model.brightness,0.4)
            XCTAssertTrue(model.notice?.contains("recovery") == true)
        }
    }
    func testModelActionsCannotFireWhileARecorderIsOpen() {
        model { model,_ in
            model.enabled = false; model.brightness = 0.4
            model.setShortcutRecording(true)
            model.performLogoShortcut(.toggle); model.performLogoShortcut(.increase)
            XCTAssertFalse(model.enabled); XCTAssertEqual(model.brightness,0.4)
            model.setShortcutRecording(false); model.performLogoShortcut(.increase)
            XCTAssertEqual(model.brightness,0.45,accuracy:0.000001)
        }
    }
    func testPreviewNeverEnablesTheHardwareFilterOrRequestsItsPermission() {
        model { model,defaults in
            XCTAssertFalse(model.shiftBrightnessEnabled); XCTAssertFalse(model.shiftBrightnessKeys.running)
            model.configureShiftBrightness(true,prompt:true)
            XCTAssertFalse(model.shiftBrightnessEnabled); XCTAssertFalse(model.shiftBrightnessKeys.running)
            XCTAssertNil(defaults.object(forKey:"shortcut.shiftBrightness.enabled"))
        }
    }
}
