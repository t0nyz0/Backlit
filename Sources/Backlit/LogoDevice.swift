import Foundation
import AppKit
import IOKit
import Darwin

/// CoreBrightness is undocumented. Capability checks and recovery are mandatory.
/// Property names and the hardware path are interoperability facts documented in
/// docs/ATTRIBUTION.md; no third-party source is included in this app.
final class LogoDevice {
    static let mappingKey = "LEPWMBrightnessNitsMapping"
    static let nodePath = "IODeviceTree:/arm-io/pwm1/bklb-backlight"
    private let reader = NSSelectorFromString("copyPropertyForKey:")
    private let writer = NSSelectorFromString("setProperty:forKey:")
    private var client: NSObject?
    private var saved: [[Double]]?
    private var lastWritten: [[Double]]?
    private var lease: FileLease?
    private let recovery: URL
    private(set) var available = false
    private(set) var explanation = "No compatible illuminated logo was detected."
    typealias Setter = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool

    init(directory: URL) {
        recovery = directory.appendingPathComponent("logo-recovery.json")
        let node = IORegistryEntryFromPath(kIOMainPortDefault, Self.nodePath)
        guard node != 0 else { return }
        IOObjectRelease(node)
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL) != nil,
              let kind = NSClassFromString("BrightnessSystemClient") as? NSObject.Type else {
            explanation = "The logo control service is unavailable on this version of macOS."
            return
        }
        let object = kind.init()
        guard object.responds(to: reader), object.responds(to: writer) else { return }
        client = object
        guard mapping() != nil else { client = nil; return }
        available = true
        explanation = "Compatible logo hardware detected."
    }

    var competingApp:String? {ControllerMonitor.shared.competingApp}

    var needsRecovery: Bool { FileManager.default.fileExists(atPath: recovery.path) }

    func read(_ key: String) -> Any? {
        client?.perform(reader, with: key)?.takeRetainedValue()
    }

    func mapping() -> [[Double]]? {
        guard let rows = read(Self.mappingKey) as? [[NSNumber]] else { return nil }
        let result = rows.map { $0.map(\.doubleValue) }
        return Self.valid(result) ? result : nil
    }

    static func valid(_ rows: [[Double]]) -> Bool {
        (2...512).contains(rows.count) && rows.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isFinite && $0 >= 0 } }
    }

    private func set(_ value: AnyObject, key: String) -> Bool {
        guard let client, let method = client.method(for: writer) else { return false }
        return unsafeBitCast(method, to: Setter.self)(client, writer, value, key as NSString)
    }

    func begin() throws {
        guard available else { throw failure(explanation) }
        if let app = competingApp { throw failure("Quit \(app) before giving Backlit the logo.") }
        let acquired = try FileLease(url:AgentBridge.directory.appendingPathComponent("logo.lock"))
        guard !needsRecovery else { throw failure("A previous session needs restoration. Choose Restore Logo Settings first.") }
        guard let original = mapping() else { throw failure("Could not read the original logo configuration.") }
        // Keep the exact pre-session curve, including a pre-existing manual value.
        try FileManager.default.createDirectory(at: recovery.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(original).write(to: recovery, options: .atomic)
        saved = original
        lease = acquired
    }

    static func requiresWrite(from previous: Double, to next: Double) -> Bool {
        // The exact off endpoint must not be swallowed by normal coalescing.
        (next == 0 && previous != 0) || abs(previous - next) >= 0.5
    }
    func apply(_ brightness: Double) throws {
        guard saved != nil else { throw failure("Logo control has not been enabled.") }
        guard brightness.isFinite else { throw failure("Invalid brightness.") }
        let nits = Effects.clamp(brightness) * 1000
        let rows: [[Double]] = [[0, nits], [Double(Float.greatestFiniteMagnitude), nits]]
        if let lastWritten {
            guard let current = mapping(), Self.equivalent(current,lastWritten) else { throw failure("Another controller changed the logo. Backlit stopped writing; recovery is retained.") }
            if !Self.requiresWrite(from: lastWritten[0][1], to: nits) { return }
        }
        guard set(rows as NSArray, key: Self.mappingKey), set(NSNumber(value: 1), key: "DisplayPowerStateEvent") else {
            throw failure("macOS rejected the logo brightness change. Restore Logo Settings before retrying.")
        }
        guard let actual = mapping(), Self.equivalent(actual, rows) else { throw failure("The logo service did not confirm the requested brightness.") }
        lastWritten = rows
    }

    func restore() throws {
        guard available else { throw failure(explanation) }
        if let app = competingApp { throw failure("Quit \(app) before restoring a previous Backlit session.") }
        guard needsRecovery || saved != nil else { return }
        if lease == nil { lease = try FileLease(url:AgentBridge.directory.appendingPathComponent("logo.lock")) }
        let original: [[Double]]
        if let saved { original = saved }
        else { original = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: recovery)) }
        guard Self.valid(original) else { throw failure("The recovery configuration is invalid; it was left untouched.") }
        if let lastWritten, let current = mapping(), !Self.equivalent(current, lastWritten) {
            throw failure("Another controller changed the logo. Its settings were left untouched; the recovery file is retained.")
        }
        guard set(original as NSArray, key: Self.mappingKey), set(NSNumber(value: 1), key: "DisplayPowerStateEvent"),
              let actual = mapping(), Self.equivalent(actual, original) else { throw failure("macOS did not confirm restoration. The recovery file is retained.") }
        if needsRecovery { try FileManager.default.removeItem(at: recovery) }
        saved = nil
        lastWritten = nil
        lease = nil
    }

    static func equivalent(_ lhs: [[Double]], _ rhs: [[Double]]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.count == b.count && zip(a,b).allSatisfy { abs($0 - $1) <= max(0.001, abs($1) * 0.000001) }
        }
    }
    static func telemetry() -> [String:Any] {
        var values: [String:Any] = [:]
        let node = IORegistryEntryFromPath(kIOMainPortDefault,nodePath)
        if node != 0 {
            func number(_ key:String)->NSNumber? {IORegistryEntryCreateCFProperty(node,key as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? NSNumber}
            if let high=number("high-period")?.doubleValue,let low=number("low-period")?.doubleValue,high+low>0 {
                values["logo_pwm_duty"]=high/(high+low)
            }
            values["logo_enabled"]=number("enabled")?.boolValue ?? false
            IOObjectRelease(node)
        }
        let screen=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleARMBacklight"))
        if screen != 0 {
            if let params=IORegistryEntryCreateCFProperty(screen,"IODisplayParameters" as CFString,kCFAllocatorDefault,0)?.takeRetainedValue() as? [String:Any],
               let brightness=params["brightness"] as? [String:Any],let value=brightness["value"] {values["screen_brightness_register"]=value}
            IOObjectRelease(screen)
        }
        return values
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "Backlit.Logo", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// Process-scoped nonblocking ownership; a second Backlit cannot overwrite a
/// live session's recovery curve. The OS releases this lock on process exit.
final class FileLease {
    private let descriptor: Int32
    init(url:URL) throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let fd = open(url.path,O_CREAT | O_RDWR | O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw RuntimeServices.failure("Could not open the logo session lock.") }
        guard flock(fd,LOCK_EX | LOCK_NB) == 0 else { close(fd); throw RuntimeServices.failure("Backlit is already running in another window. Use the installed copy.") }
        descriptor = fd
    }
    deinit { _ = flock(descriptor,LOCK_UN); close(descriptor) }
}
