import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Darwin

enum RuntimeServices {
    struct BatterySnapshot: Equatable {
        let level: Double
        let externalPower: Bool
        let activelyCharging: Bool
    }

    // Read active charging separately from AC power: charge limits, optimized
    // charging and a full battery can all leave a Mac plugged in but not charging.
    static func batterySnapshot(description value: [String: Any]) -> BatterySnapshot? {
        guard value[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              value[kIOPSIsPresentKey] as? Bool != false,
              let current = value[kIOPSCurrentCapacityKey] as? Double, current.isFinite, current >= 0,
              let maximum = value[kIOPSMaxCapacityKey] as? Double, maximum.isFinite, maximum > 0,
              let state = value[kIOPSPowerSourceStateKey] as? String,
              state == kIOPSACPowerValue || state == kIOPSBatteryPowerValue,
              let isCharging = value[kIOPSIsChargingKey] as? Bool else { return nil }
        let level = Effects.clamp(current / maximum)
        let externalPower = state == kIOPSACPowerValue
        let full = level >= 1 || value[kIOPSIsChargedKey] as? Bool == true
        return BatterySnapshot(level: level, externalPower: externalPower,
                               activelyCharging: externalPower && isCharging && !full)
    }

    static func batterySnapshot() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            if let value = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let snapshot = batterySnapshot(description: value) { return snapshot }
        }
        return nil
    }

    static func battery() -> (Double, Bool) {
        guard let snapshot = batterySnapshot() else { return (0, false) }
        return (snapshot.level, snapshot.externalPower)
    }
    static func rootValue(_ key: String) -> Any? {
        let node = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard node != 0 else { return nil }; defer { IOObjectRelease(node) }
        return IORegistryEntryCreateCFProperty(node, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    static var physicalLidClosed: Bool? { (rootValue("AppleClamshellState") as? NSNumber)?.boolValue }
    static var lidClosed: Bool { physicalLidClosed ?? false }
    static var locked: Bool { (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false }
    static var away: Bool { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .null) > 60 }
    static var externalDisplay: Bool { NSScreen.screens.count > 1 || (NSScreen.screens.first?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32).map { CGDisplayIsBuiltin($0) == 0 } == true }

    /// Runs as a separate unprivileged watchdog. Selector/type come from Apple's
    /// RootDomainUserClient.cpp and the installed IOPMLibDefs.h, not guessed IDs.
    static func watchLid(parent: pid_t, lease: URL, durationSeconds: Double = 1800, intentID: UUID? = nil) -> Int32 {
        guard LidSessionPolicy.validDuration(durationSeconds) else { return 12 }
        // Install graceful child-only cancellation before opening or changing power services.
        let cancellation = LidWatchCancellation()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return 2 }; defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return 3 }
        guard let logoInterface = ClosedLidLogo.liveInterface() else { IOServiceClose(connection); return 7 }
        let logo = ClosedLidLogo(interface: logoInterface)
        var changed = false
        var assertion: IOPMAssertionID = 0
        let journal = AgentBridge.directory.appendingPathComponent("lid-recovery.json")
        guard !FileManager.default.fileExists(atPath: journal.path) else { IOServiceClose(connection); return 9 }
        func setDisabled(_ disabled: Bool) -> Bool {
            var scalar: UInt64 = disabled ? 1 : 0
            return IOConnectCallScalarMethod(connection, 12, &scalar, 1, nil, nil) == KERN_SUCCESS
        }
        func recordRecovery(effectsAllowed: Bool = false) throws {
            let bytes = try JSONSerialization.data(withJSONObject: ["needsRestore": changed, "logoOverride": logo.active, "effectsAllowed": effectsAllowed])
            try bytes.write(to: journal, options: .atomic)
        }
        func restoreLogo(_ closed: Bool?) throws {
            _ = try ClosedEffectSession.locked(wait: true) {
                // Revoke under the same lock before touching hardware. Preserve
                // recovery ownership until every independent reset succeeds.
                try recordRecovery(effectsAllowed: false)
                try logo.restore(physicalClosed: closed)
                try recordRecovery(effectsAllowed: false)
            }
        }
        defer {
            var restored = true
            do { try restoreLogo(physicalLidClosed) } catch { restored = false }
            if changed && !setDisabled(false) { restored = false }
            if restored { try? FileManager.default.removeItem(at: journal) }
            if assertion != 0 { IOPMAssertionRelease(assertion) }
            IOServiceClose(connection)
        }
        var logoEnabledAt: Double?
        var closedAt: Double?
        var exhausted = false
        let intent = intentID.flatMap { LidSessionIntent(id: $0, durationSeconds: durationSeconds) }
        let checkpoints = LidTimerCheckpointStore(directory: AgentBridge.directory)
        let timer = intent.map { intent in
            LidTimerMonitor(intent: intent, read: { checkpoints.read(intent.id) }, write: { try checkpoints.write($0) })
        }
        while !cancellation.isRequested && kill(parent, 0) == 0 && FileManager.default.fileExists(atPath: lease.path) {
            guard let closed = physicalLidClosed else { return 10 }
            let power = battery()
            let thermal = ProcessInfo.processInfo.thermalState
            if let timer {
                // Durable before any power override or logo permission grant.
                do { exhausted = try !timer.update(closed: closed, clock: LidContinuousClock.live()) }
                catch { return 13 }
            } else {
                // Legacy explicit helper invocations retain their bounded timer.
                if !closed { closedAt = nil; exhausted = false }
                if closed && closedAt == nil { closedAt = ProcessInfo.processInfo.systemUptime }
                if LidSessionPolicy.timedOut(closedAt: closedAt, now: ProcessInfo.processInfo.systemUptime, duration: durationSeconds) { exhausted = true }
            }
            let eligible = LidSessionPolicy.eligible(exhausted: exhausted, externalPower: power.1,
                battery: power.0, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: thermal) && LidResumeSafety.sessionUnlocked()
            // Restore the logo gate before allowing sleep or dropping the assertion.
            if (!eligible || !closed) && logo.active {
                do { try restoreLogo(closed); logoEnabledAt = nil; try recordRecovery() } catch { return 8 }
            }
            if eligible && !changed && ((rootValue("AppleClamshellCausesSleep") as? NSNumber)?.boolValue == true) {
                do { try JSONSerialization.data(withJSONObject: ["needsRestore": true, "logoOverride": logo.active]).write(to: journal, options: .atomic) } catch { return 4 }
                // Retain recovery even if the private call reports failure.
                changed = true
                guard setDisabled(true) else { return 5 }
            } else if !eligible && changed {
                guard setDisabled(false) else { return 6 }
                changed = false
                do { try recordRecovery() } catch { return 4 }
                if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
            }
            if eligible && closed && assertion == 0 {
                _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn), "Backlit bounded closed-lid session" as CFString, &assertion)
            } else if (!eligible || !closed) && assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
            do {
                if eligible && closed {
                    try logo.enable {
                        // Must be durable before the first global notification.
                        try JSONSerialization.data(withJSONObject: ["needsRestore": changed, "logoOverride": true]).write(to: journal, options: .atomic)
                    }
                    if logo.active && logoEnabledAt == nil {
                        logoEnabledAt = ProcessInfo.processInfo.systemUptime
                        _ = try ClosedEffectSession.locked(wait: true) { try recordRecovery(effectsAllowed: true) }
                    }
                    // Allow the keyboard fade to settle, then fail closed if it is
                    // not confirmed dark. A rejected private API must not leave it lit.
                    if let since = logoEnabledAt, ProcessInfo.processInfo.systemUptime - since >= 1 {
                        let node = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pwm0/kbd-backlight")
                        let enabled = node == 0 ? nil : (IORegistryEntryCreateCFProperty(node, "enabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.boolValue
                        if node != 0 { IOObjectRelease(node) }
                        // A real reopen may wake the keyboard between our two
                        // samples. Restore normally rather than report a failure.
                        if enabled != false {
                            if physicalLidClosed == false {
                                try restoreLogo(false)
                                logoEnabledAt = nil
                                try recordRecovery()
                            } else { return 11 }
                        }
                    }
                }
            } catch { return 8 }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return 0
    }

    static func repairLid(forcePowerRestore: Bool = false) throws {
        let journal = AgentBridge.directory.appendingPathComponent("lid-recovery.json")
        let hasJournal = FileManager.default.fileExists(atPath: journal.path)
        guard hasJournal || forcePowerRestore else { return }
        let record = hasJournal
            ? try JSONDecoder().decode(LidRecovery.self, from: Data(contentsOf: journal))
            : LidRecovery(needsRestore: false, logoOverride: false)
        try repairLid(record: hasJournal ? record : nil, forcePowerRestore: forcePowerRestore, logo: {
            _ = try ClosedEffectSession.locked(wait: true) {
                // Encoding the recovery record removes live effect permission.
                // Keep its ownership bits until every independent reset works.
                try JSONEncoder().encode(record).write(to: journal, options: .atomic)
                guard let io = ClosedLidLogo.liveInterface() else { throw failure("Logo recovery controls are unavailable. Recovery is retained.") }
                let lidRestored = physicalLidClosed.map(io.setGlobalClosed) ?? false
                let effectRestored = io.restoreEffect()
                guard lidRestored && effectRestored else { throw failure("Could not restore the real logo lid state. Recovery is retained.") }
            }
        }, power: {
            let node = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            guard node != 0 else { throw failure("Power service unavailable.") }; defer { IOObjectRelease(node) }
            var connection: io_connect_t = 0
            guard IOServiceOpen(node, mach_task_self_, 0, &connection) == KERN_SUCCESS else { throw failure("Cannot reopen the power service.") }
            defer { IOServiceClose(connection) }
            var value: UInt64 = 0
            guard IOConnectCallScalarMethod(connection, 12, &value, 1, nil, nil) == KERN_SUCCESS else { throw failure("Could not restore normal lid sleep.") }
            // AppleClamshellCausesSleep describes aggregate system policy, not
            // ownership of this override. Normal external-display mode can keep
            // it false after this reset succeeds.
        }, removeJournal: { try FileManager.default.removeItem(at: journal) })
    }

    /// Offline-testable recovery ordering. Retire the journal only after every
    /// requested restoration succeeds, without imposing a system sleep policy.
    static func repairLid(record: LidRecovery?, forcePowerRestore: Bool = false,
                          logo: () throws -> Void, power: () throws -> Void,
                          removeJournal: () throws -> Void) throws {
        guard record != nil || forcePowerRestore else { return }
        try (record ?? LidRecovery(needsRestore: false, logoOverride: false))
            .restore(forceNormalSleep: forcePowerRestore, logo: logo, power: power)
        if record != nil { try removeJournal() }
    }

    static func authorizedAmbient(_ enabled: Bool) throws {
        guard let binary = Bundle.main.executableURL?.path else { throw failure("App executable missing.") }
        let command = "'" + binary.replacingOccurrences(of: "'", with: "'\\''") + "' --ambient-helper " + (enabled ? "enable" : "restore")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with prompt \"Backlit wants to \(enabled ? "unlock" : "restore") the logo brightness range.\" with administrator privileges")!
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error { throw AmbientAuthorizationFailure(scriptError: error) }
    }

    /// This branch only executes under the system's administrator authorization.
    static func ambientHelper(enabled: Bool) throws {
        guard geteuid() == 0 else { throw failure("Administrator authorization is required.") }
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: "/var/db/local.backlit")
        if manager.fileExists(atPath: folder.path) {
            let attr = try manager.attributesOfItem(atPath: folder.path)
            guard attr[.type] as? FileAttributeType == .typeDirectory, (attr[.ownerAccountID] as? NSNumber)?.intValue == 0 else { throw failure("Invalid recovery directory.") }
        } else { try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let backup = folder.appendingPathComponent("ambient.plist")
        let domain = "com.apple.CoreBrightness" as CFString
        let keys = ["LEPWMLuxToMinNitsRestrictionMapping", "LEPWMLuxToMaxNitsRestrictionMapping"]
        if manager.fileExists(atPath: backup.path) {
            let attr = try manager.attributesOfItem(atPath: backup.path)
            guard attr[.type] as? FileAttributeType == .typeRegular else { throw failure("Invalid recovery file.") }
        }
        if enabled && !manager.fileExists(atPath: backup.path) {
            var values: [String: Any] = [:]
            for key in keys { if let value = CFPreferencesCopyAppValue(key as CFString, domain) { values[key] = value } }
            let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try bytes.write(to: backup, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        guard manager.fileExists(atPath: backup.path) else { throw failure("No saved brightness limits to restore.") }
        let originals = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any] ?? [:]
        for (i,key) in keys.enumerated() {
            let value: Any? = enabled ? [[0.0, i == 0 ? 12.5 : 1000.0], [Double(Float.greatestFiniteMagnitude), i == 0 ? 12.5 : 1000.0]] : originals[key]
            CFPreferencesSetAppValue(key as CFString, value as CFPropertyList?, domain)
        }
        guard CFPreferencesAppSynchronize(domain) else { throw failure("Could not save brightness limits; recovery is retained.") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); process.arguments = ["-TERM", "corebrightnessd"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if !enabled { try manager.removeItem(at: backup) }
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "Backlit", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
}
