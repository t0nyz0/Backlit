import Foundation
import Darwin

/// A temporary, capability-checked CoreBrightness lid notification override.
/// It does not alter the physical lid state, brightness preferences or security settings.
/// The owning watchdog must restore the real lid state on every exit path.
final class ClosedLidLogo {
    struct Interface {
        var daemonClosed: () -> Bool?
        var keyboardIDs: () -> [UInt64]?
        var setGlobalClosed: (Bool) -> Bool
        var setKeyboardClosed: (UInt64, Bool) -> Bool
        var restoreEffect: () -> Bool = { true }
        var restoreDisplayLidState: (Bool) -> Bool = { _ in true }
    }
    private let io: Interface
    private(set) var active = false
    init(interface: Interface) { io = interface }

    /// Wait for macOS to process the real close event before overriding it.
    /// Persist recovery before the first write; keep it even after partial failure.
    func enable(recordRecovery: () throws -> Void) throws {
        guard !active else { return }
        guard io.daemonClosed() == true else { return }
        guard let ids = io.keyboardIDs(), !ids.isEmpty else {
            throw RuntimeServices.failure("Keyboard safety controls are unavailable. Closed-lid lighting was not enabled.")
        }
        try recordRecovery()
        active = true
        guard io.setGlobalClosed(false) else {
            throw RuntimeServices.failure("macOS rejected closed-lid lighting. Restore the lid session before retrying.")
        }
        // Global notification also reaches display color modules. Restore their
        // real lid state immediately; never change True Tone preferences.
        let displaysRestored = io.restoreDisplayLidState(true)
        var keyboardsSafe = true
        for id in ids { keyboardsSafe = io.setKeyboardClosed(id, true) && keyboardsSafe }
        guard displaysRestored && keyboardsSafe else {
            throw RuntimeServices.failure("Could not preserve display and keyboard behavior. Closed-lid lighting was stopped.")
        }
    }

    func restore(physicalClosed: Bool?) throws {
        guard active else { return }
        let lidRestored = physicalClosed.map(io.setGlobalClosed) ?? false
        let effectRestored = io.restoreEffect()
        guard lidRestored && effectRestored else {
            throw RuntimeServices.failure("Could not restore the real lid state. Recovery has been retained.")
        }
        active = false
    }

    static func liveInterface() -> Interface? {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL) != nil,
              let kind = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              let keyboardKind = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = kind.init(), keyboard = keyboardKind.init()
        let reader = NSSelectorFromString("copyPropertyForKey:")
        let writer = NSSelectorFromString("setProperty:forKey:")
        let keyboardWriter = NSSelectorFromString("setProperty:withKey:keyboardID:")
        let idsReader = NSSelectorFromString("copyKeyboardBacklightIDs")
        let displayWriter = NSSelectorFromString("setProperty:withKey:andDisplay:")
        // The display setter shares the keyboard setter's signature; both are
        // called through the same casted function type below.
        guard PrivateInterface.matches(client, reader, PrivateInterface.copyProperty),
              PrivateInterface.matches(client, writer, PrivateInterface.setProperty),
              PrivateInterface.matches(client, keyboardWriter, PrivateInterface.setScopedProperty),
              PrivateInterface.matches(client, displayWriter, PrivateInterface.setScopedProperty),
              PrivateInterface.matches(keyboard, idsReader, PrivateInterface.copyKeyboardIDs) else { return nil }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
        typealias KeyboardSetter = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool
        return Interface(
            daemonClosed: { (client.perform(reader, with: "CBClamshellState")?.takeRetainedValue() as? NSNumber)?.boolValue },
            keyboardIDs: {
                guard let ids = keyboard.perform(idsReader)?.takeRetainedValue() as? [NSNumber] else { return nil }
                return ids.map(\.uint64Value)
            },
            setGlobalClosed: { closed in
                unsafeBitCast(client.method(for: writer), to: Setter.self)(client, writer, NSNumber(value: closed), "ClamshellUpdate")
            },
            setKeyboardClosed: { id, closed in
                unsafeBitCast(client.method(for: keyboardWriter), to: KeyboardSetter.self)(client, keyboardWriter, NSNumber(value: closed), "ClamshellUpdate", id)
            }, restoreEffect: {
                // FadeRuntime alone owns verified fade recovery. This lid-only
                // owner must never issue a competing global logical-state reset.
                true
            }, restoreDisplayLidState: { closed in
                guard let list = client.perform(reader, with: "CBDisplayList")?.takeRetainedValue() as? [String: Any],
                      let displays = list["CBDisplayDeviceIDs"] as? [NSNumber] else { return false }
                var restored = true
                for display in displays {
                    let accepted = unsafeBitCast(client.method(for: displayWriter), to: KeyboardSetter.self)(client, displayWriter, NSNumber(value: closed), "ClamshellUpdate", display.uint64Value)
                    restored = accepted && restored
                }
                return restored
            })
    }
}
