import AppKit
import CoreGraphics
import Darwin
import IOKit
import IOKit.pwr_mgt
import ObjectiveC

/// Capability-checked hardware boundary. Creating this adapter only installs
/// observers and reads state. The owner must obtain durable recovery permission
/// before calling either write method. Tests use Interface, never makeLive().
final class LiveFadeHardware {
    struct Interface {
        var context: () -> FadeSafetyContext?
        var keyboardIDs: () -> [UInt64]?
        var keyboardState: (UInt64) -> NSNumber?
        var duration: (Double) -> Bool
        var logicalState: (Int) -> Bool
        var keyboardLogicalState: (UInt64, Int) -> Bool
        var keyboardClosed: (UInt64) -> Bool
        var factor: () -> Double?
        var logoEnabled: () -> Bool?
        var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
        var wait: (Double) -> Void = { interval in
            let deadline = ProcessInfo.processInfo.systemUptime + interval
            RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
            // A run loop without a ready source may return early. Do not spin
            // or collapse the interval between independent terminal samples.
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        }
    }

    private let io: Interface
    private let operationLock = NSRecursiveLock()
    init(interface: Interface) { io = interface }

    func currentContext() -> FadeSafetyContext? { io.context() }

    func keyboardStates() -> [UInt64: Int]? {
        guard let ids = io.keyboardIDs(), !ids.isEmpty,
              Set(ids).count == ids.count else { return nil }
        var result: [UInt64: Int] = [:]
        for id in ids {
            guard let number = io.keyboardState(id),
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...6).contains(number.doubleValue),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            result[id] = number.intValue
        }
        // A replacement while reading must not become an apparently complete
        // snapshot. No cached keyboard IDs are used for subsequent batches.
        guard let after = io.keyboardIDs(), Set(after) == Set(ids),
              after.count == ids.count else { return nil }
        return result
    }

    func guardedFadeWrite(_ body: () throws -> Void) throws {
        operationLock.lock(); defer { operationLock.unlock() }
        try FadeKeyboardGuard(interface: .init(
            context: io.context, keyboardStates: self.keyboardStates,
            setLogicalState: io.keyboardLogicalState,
            setClosed: io.keyboardClosed)).perform(body)
    }

    /// Setter acceptance does not prove an old fade actually stopped. This
    /// read-only confirmation is also required after a healthy owner's guarded
    /// restore. No persistent recovery record may be cleared until it succeeds.
    func confirmTerminal() throws {
        operationLock.lock(); defer { operationLock.unlock() }
        let deadline = try terminalDeadline()
        guard let context = currentContext() else {
            throw RuntimeServices.failure("Power state is unknown. Fade recovery is retained.")
        }
        try confirmTerminal(context: context, deadline: deadline)
    }

    private func terminalDeadline() throws -> Double {
        let now = io.now(), deadline = now + 6
        guard now.isFinite, now >= 0, deadline.isFinite, deadline > now else {
            throw RuntimeServices.failure("The fade recovery clock is unavailable.")
        }
        return deadline
    }

    private func confirmTerminal(context: FadeSafetyContext, deadline: Double) throws {
        var candidate: Double?
        var candidateSince: Double?
        var previousTime: Double?
        // The deadline is fixed for the whole attempt, never extended by new
        // samples. The count also bounds a faulty injected/nonadvancing wait.
        for _ in 0..<128 {
            let now = io.now()
            guard now.isFinite, now >= 0, now <= deadline,
                  previousTime.map({ now > $0 }) ?? true else {
                throw RuntimeServices.failure("The fade did not reach a verified endpoint in time. Recovery is retained.")
            }
            guard currentContext() == context,
                  let factor = io.factor(), factor.isFinite, (0...1).contains(factor) else {
                throw RuntimeServices.failure("Fade output or safety state is unknown. Recovery is retained.")
            }
            var terminal = factor == 0 || (context.permitsOpenKeyboardRestore && factor == 1)
            if !context.permitsOpenKeyboardRestore {
                guard let enabled = io.logoEnabled() else {
                    throw RuntimeServices.failure("The logo's off state could not be verified. Fade recovery is retained.")
                }
                terminal = terminal && !enabled
            }
            let checkedAt = io.now()
            guard currentContext() == context, checkedAt.isFinite,
                  checkedAt >= now, checkedAt <= deadline else {
                throw RuntimeServices.failure("Safety state changed while verifying fade output. Recovery is retained.")
            }
            // Two identical terminal samples distinguish an observed settled
            // endpoint from a single stale read during a native transition.
            if terminal, candidate == factor, let candidateSince,
               checkedAt >= candidateSince + 0.05 { return }
            if !terminal {
                candidate = nil; candidateSince = nil
            } else if candidate != factor {
                candidate = factor; candidateSince = checkedAt
            }
            guard checkedAt < deadline else {
                throw RuntimeServices.failure("The fade is still active. Recovery is retained.")
            }
            previousTime = checkedAt
            io.wait(min(0.05, deadline - checkedAt))
        }
        throw RuntimeServices.failure("Fade output did not settle. Recovery is retained.")
    }

    /// Recovery belongs to a different process/generation from the saved record.
    /// Neither originalContext nor pendingBatch can authorize replaying Unblank.
    /// Preserve a fresh keyboard snapshot only across this recovery's own stable
    /// safety generation. This does not attempt to repair a latched-zero mapping.
    func restore(_ record: FadeRecoveryRecord) throws {
        // The journal persists a batch before its first possible hardware write.
        // An unacknowledged/unused session has nothing to undo on the device.
        guard record.pendingBatch != nil else { return }
        operationLock.lock(); defer { operationLock.unlock() }
        let deadline = try terminalDeadline()
        guard let before = currentContext(), let saved = keyboardStates(),
              currentContext() == before else {
            throw RuntimeServices.failure("Current power and keyboard state could not be verified. Fade recovery is retained.")
        }
        var failure: Error?
        func write(_ action: () -> Bool) throws {
            guard currentContext() == before, action() else {
                throw RuntimeServices.failure("Power state changed or macOS rejected fade recovery.")
            }
        }
        do {
            if before.permitsOpenKeyboardRestore {
                // A bounded reverse step avoids leaving another effectively
                // infinite ramp if the reset is interrupted halfway through.
                try write { io.duration(5) }
                try write { io.logicalState(1) }
                try write { io.duration(0) }
                try write { io.logicalState(2) }
            } else {
                // Never issue even a temporary global Unblank while closed,
                // sleeping or locked, solely to reverse the fade direction.
                try write { io.duration(0) }
                try write { io.logicalState(1) }
            }
        } catch { failure = error }

        // As with a normal batch, partial global failures still restore every
        // known keyboard. Re-read context separately for each device.
        let observed = keyboardStates()
        let ids = Set(saved.keys).union(observed.map { Set($0.keys) } ?? [])
        var restored = observed != nil && Set(saved.keys) == Set(observed!.keys)
        for id in ids.sorted() {
            guard let current = currentContext() else { restored = false; continue }
            let accepted: Bool
            if current.lidClosed {
                accepted = io.keyboardClosed(id)
            } else if observed != nil, current == before,
                      current.permitsOpenKeyboardRestore, let state = saved[id] {
                // A crashed global write may itself have left a fresh-looking
                // Unblank here. Recovery cannot prove its provenance, unlike a
                // live guarded batch, so leave it dark for macOS to reconcile.
                accepted = io.keyboardLogicalState(id, state == 2 ? 1 : state)
            } else {
                accepted = io.keyboardLogicalState(id, 1)
            }
            restored = accepted && restored
        }
        guard restored, currentContext() == before else {
            throw RuntimeServices.failure("Keyboard safety changed during recovery. Fade recovery is retained.")
        }
        if let failure { throw failure }
        // An already-held Blank can ignore a duration/state write. Wait for
        // actual output instead of assuming acceptance repaired that old ramp.
        try confirmTerminal(context: before, deadline: deadline)
    }

    static func makeLive() throws -> LiveFadeHardware {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY | RTLD_LOCAL) != nil,
              let kind = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              let keyboardKind = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            throw RuntimeServices.failure("CoreBrightness fade controls are unavailable.")
        }
        let client = kind.init(), keyboard = keyboardKind.init()
        let reader = NSSelectorFromString("copyPropertyForKey:keyboardID:")
        let globalReader = NSSelectorFromString("copyPropertyForKey:")
        let writer = NSSelectorFromString("setProperty:withKey:keyboardID:")
        let globalWriter = NSSelectorFromString("setProperty:forKey:")
        let idsReader = NSSelectorFromString("copyKeyboardBacklightIDs")
        func hasABI(_ object: NSObject, _ selector: Selector, _ encoding: String) -> Bool {
            guard object.responds(to: selector), let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector),
                  let actual = method_getTypeEncoding(method) else { return false }
            return String(cString: actual) == encoding
        }
        guard hasABI(client, reader, "@32@0:8@16Q24"),
              hasABI(client, globalReader, "@24@0:8@16"),
              hasABI(client, writer, "B40@0:8@16@24Q32"),
              hasABI(client, globalWriter, "B32@0:8@16@24"),
              hasABI(keyboard, idsReader, "@16@0:8") else {
            throw RuntimeServices.failure("CoreBrightness keyboard safety controls have an unsupported interface.")
        }
        typealias Reader = @convention(c) (AnyObject, Selector, NSString, UInt64) -> Unmanaged<AnyObject>?
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool
        typealias GlobalSetter = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
        let read = unsafeBitCast(client.method(for: reader), to: Reader.self)
        let set = unsafeBitCast(client.method(for: writer), to: Setter.self)
        let globalSet = unsafeBitCast(client.method(for: globalWriter), to: GlobalSetter.self)
        let monitor = try LiveFadeSafetyMonitor()
        let hardware = LiveFadeHardware(interface: .init(context: { monitor.context() }, keyboardIDs: {
            guard let numbers = keyboard.perform(idsReader)?.takeRetainedValue() as? [NSNumber] else { return nil }
            var ids: [UInt64] = []
            for number in numbers {
                guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0,
                      number.compare(NSNumber(value: number.uint64Value)) == .orderedSame else { return nil }
                ids.append(number.uint64Value)
            }
            return ids
        }, keyboardState: { id in
            // copy-family ownership, including the keyboard-specific getter.
            read(client, reader, "DisplayLogicalState", id)?.takeRetainedValue() as? NSNumber
        }, duration: { value in
            globalSet(client, globalWriter, NSNumber(value: value), "LEPWMFactorFadeDuration")
        }, logicalState: { state in
            globalSet(client, globalWriter, NSNumber(value: state), "DisplayLogicalState")
        }, keyboardLogicalState: { id, state in
            set(client, writer, NSNumber(value: state), "DisplayLogicalState", id)
        }, keyboardClosed: { id in
            set(client, writer, NSNumber(value: true), "ClamshellUpdate", id)
        }, factor: {
            guard let state = client.perform(globalReader, with: "LEPWMState")?.takeRetainedValue() as? [String: NSNumber],
                  let factor = state["Factor"], CFGetTypeID(factor) != CFBooleanGetTypeID() else { return nil }
            return factor.doubleValue
        }, logoEnabled: {
            LogoDevice.enabledState()
        }))
        guard hardware.currentContext() != nil, hardware.keyboardStates() != nil else {
            throw RuntimeServices.failure("Current lid, sleep, lock and keyboard state must be known before using fades.")
        }
        return hardware
    }
}

/// Pure state machine shared by the live notification monitor and fixture tests.
/// The generation is process-local; it must never be compared across processes.
final class FadeSafetyObservation {
    struct State: Equatable {
        let lidClosed: Bool
        let sleeping: Bool
        let locked: Bool
        var sleepCycle: String? = nil
    }
    enum Event {
        case changed, willSleep, didWake, resignedSession, activeSession, locked, unlocked
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var exhausted = false
    private var last: State?
    private var sleepObserved = false
    private var inactiveObserved = false
    private var lockObserved = false

    private func advance() {
        if generation == .max { exhausted = true } else { generation += 1 }
    }
    func observe(_ event: Event) {
        lock.lock(); defer { lock.unlock() }
        advance() // Even an away-and-back event invalidates the old snapshot.
        switch event {
        case .changed: break
        case .willSleep: sleepObserved = true
        case .didWake: sleepObserved = false
        case .resignedSession: inactiveObserved = true
        case .activeSession: inactiveObserved = false
        case .locked: lockObserved = true
        case .unlocked: lockObserved = false
        }
    }
    func context(read: () -> State?) -> FadeSafetyContext? {
        lock.lock(); let startingGeneration = generation; lock.unlock()
        let sampled = read()
        lock.lock(); defer { lock.unlock() }
        guard generation == startingGeneration, !exhausted else { return nil }
        guard let sampled else {
            if last != nil { advance(); last = nil }
            return nil
        }
        let current = State(lidClosed: sampled.lidClosed,
                            sleeping: sampled.sleeping || sleepObserved,
                            locked: sampled.locked || inactiveObserved || lockObserved,
                            sleepCycle: sampled.sleepCycle)
        if current != last { advance(); last = current }
        guard !exhausted else { return nil }
        return FadeSafetyContext(lidClosed: current.lidClosed, sleeping: current.sleeping,
                                 locked: current.locked, generation: generation)
    }
}

private final class LiveFadeSafetyMonitor {
    // The callback owns only this relay, not the monitor. Port teardown drains
    // callbacks before releasing it; notification closures capture it strongly.
    private final class Relay {
        let observation = FadeSafetyObservation()
    }
    private let relay = Relay()
    private let queue = DispatchQueue(label: "Backlit.fade-safety-observations")
    private var port: IONotificationPortRef?
    private var interest: io_object_t = 0
    private var root: io_service_t = 0
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []

    init() throws {
        root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw RuntimeServices.failure("Power-state observation is unavailable.")
        }
        self.port = port
        let result = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { pointer, _, message, _ in
            guard let pointer else { return }
            let relay = Unmanaged<Relay>.fromOpaque(pointer).takeUnretainedValue()
            // IOPM.h macros are unavailable to Swift. Expand the SDK's
            // iokit_family_msg(sys_iokit | err_sub(13) | message) exactly:
            // ClamshellStateChange = 0x100; SleepWakeUUIDChange = 0x140.
            let powerMessages: UInt32 = 0xe0000000 | (13 << 14)
            if message == (powerMessages | 0x100) ||
               message == (powerMessages | 0x140) {
                relay.observation.observe(.changed)
            }
        }, Unmanaged.passUnretained(relay).toOpaque(), &interest)
        guard result == KERN_SUCCESS else {
            throw RuntimeServices.failure("Lid-change observation is unavailable.")
        }
        IONotificationPortSetDispatchQueue(port, queue)
        let workspace = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, FadeSafetyObservation.Event)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidSleepNotification, .changed),
            (NSWorkspace.screensDidWakeNotification, .changed),
            (NSWorkspace.sessionDidResignActiveNotification, .resignedSession),
            (NSWorkspace.sessionDidBecomeActiveNotification, .activeSession)
        ]
        for (name, event) in events {
            let relay = self.relay
            let token = workspace.addObserver(forName: name, object: nil, queue: nil) { _ in relay.observation.observe(event) }
            notifications.append((workspace, token))
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, event): (String, FadeSafetyObservation.Event) in [
            ("com.apple.screenIsLocked", .locked), ("com.apple.screenIsUnlocked", .unlocked)
        ] {
            let relay = self.relay
            let token = distributed.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in relay.observation.observe(event) }
            notifications.append((distributed, token))
        }
    }

    deinit {
        for (center, token) in notifications { center.removeObserver(token) }
        if interest != 0 { IOObjectRelease(interest) }
        if let port {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
            queue.sync {} // The callback does not retain/call this monitor.
        }
        if root != 0 { IOObjectRelease(root) }
    }

    func context() -> FadeSafetyContext? {
        relay.observation.context {
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(root, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let lid = dictionary[kAppleClamshellStateKey] as? Bool,
                  let session = CGSessionCopyCurrentDictionary() as? [String: Any],
                  let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool,
                  let loginDone = session[kCGSessionLoginDoneKey as String] as? Bool else { return nil }
            // This key is normally absent for a validated unlocked console
            // session. Absence is distinct from a failed/malformed dictionary.
            let lockValue = session["CGSSessionScreenIsLocked"]
            guard lockValue == nil || lockValue is Bool else { return nil }
            let locked = lockValue as? Bool ?? false
            // UUID changes invalidate snapshots, but UUID presence by itself is
            // not a sufficiently reliable indication of current sleep status.
            let cycle = dictionary[kIOPMSleepWakeUUIDKey]
            guard cycle == nil || cycle is String else { return nil }
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(0, nil, &count) == .success,
                  count > 0, count <= 64 else { return nil }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            var actual: UInt32 = 0
            guard CGGetOnlineDisplayList(count, &displays, &actual) == .success,
                  actual > 0, actual <= count else { return nil }
            // No validated awake display is unsafe. This intentionally blocks
            // a closed/no-external-display configuration until a separate,
            // trustworthy initial system-awake source has been verified.
            let sleeping = displays.prefix(Int(actual)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
            return .init(lidClosed: lid, sleeping: sleeping, locked: locked || !onConsole || !loginDone,
                         sleepCycle: cycle as? String)
        }
    }
}
