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
        for id in ids {
            guard io.setKeyboardClosed(id, true) else {
                throw RuntimeServices.failure("Could not keep the keyboard dark. Closed-lid lighting was stopped.")
            }
        }
    }

    func restore(physicalClosed: Bool?) throws {
        guard active else { return }
        guard let physicalClosed, io.setGlobalClosed(physicalClosed) else {
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
        guard client.responds(to: reader), client.responds(to: writer),
              client.responds(to: keyboardWriter), keyboard.responds(to: idsReader) else { return nil }
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
            })
    }
}
