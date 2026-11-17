import AppKit
import Carbon

enum LogoShortcutAction: UInt32, CaseIterable, Identifiable, Codable {
    case toggle = 1, decrease = 2, increase = 3
    static let signature: OSType = 0x424c4954
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .toggle: return "Toggle logo"
        case .decrease: return "Decrease logo brightness"
        case .increase: return "Increase logo brightness"
        }
    }
    var preferenceKey: String { "shortcut.v2." + String(rawValue) }
    var defaultBinding: LogoShortcut? {
        self == .toggle ? legacyDefaultBinding : nil
    }
    /// Used only to preserve shortcuts already active in older installations.
    var legacyDefaultBinding: LogoShortcut {
        switch self {
        case .toggle: return .init(keyCode:11,modifiers:4352,keyLabel:"B")
        case .decrease: return .init(keyCode:125,modifiers:4352,keyLabel:"↓")
        case .increase: return .init(keyCode:126,modifiers:4352,keyLabel:"↑")
        }
    }
}

struct ShortcutError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LogoShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    static let primaryModifiers = UInt32(cmdKey | controlKey | optionKey)
    static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    var label: String {
        [(UInt32(controlKey),"⌃"),(UInt32(optionKey),"⌥"),(UInt32(shiftKey),"⇧"),(UInt32(cmdKey),"⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyLabel
    }
    func matches(_ other: LogoShortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    func validate() throws {
        guard keyCode <= 127, !(54...63).contains(keyCode), modifiers & Self.primaryModifiers != 0,
              modifiers & ~Self.allowedModifiers == 0, !keyLabel.isEmpty, keyLabel.count <= 32,
              keyLabel.unicodeScalars.allSatisfy({!CharacterSet.controlCharacters.contains($0)}) else {
            throw ShortcutError(message:"Use Command, Control or Option with a regular key. Shift alone and hardware brightness keys are not supported.")
        }
    }
    static func capture(_ event: NSEvent) throws -> LogoShortcut {
        guard event.type == .keyDown else {
            throw ShortcutError(message:"Hardware brightness keys are left to macOS. Use an arrow, letter or other regular key.")
        }
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let labels: [UInt16:String] = [123:"←",124:"→",125:"↓",126:"↑",49:"Space",48:"Tab",36:"Return",76:"Enter",51:"Delete",117:"Forward Delete",53:"Escape",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        let label = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        let binding = LogoShortcut(keyCode:UInt32(event.keyCode),modifiers:modifiers,keyLabel:label)
        try binding.validate()
        return binding
    }
}

enum LogoShortcutPreferences {
    static func load(_ defaults: UserDefaults) -> [LogoShortcutAction:LogoShortcut] {
        // Capture older implicit bindings before adopting the new defaults. Explicit
        // bindings (including null/disabled) are never overwritten.
        if !defaults.bool(forKey:"shortcut.defaults.v3") { // gitleaks:allow -- preference migration marker, not a credential
            if defaults.string(forKey:"installation.id") != nil {
                for action in [LogoShortcutAction.decrease, .increase] where defaults.object(forKey:action.preferenceKey) == nil {
                    defaults.set(try? JSONEncoder().encode(action.legacyDefaultBinding),forKey:action.preferenceKey)
                }
            }
            defaults.set(true,forKey:"shortcut.defaults.v3") // gitleaks:allow -- preference migration marker, not a credential
        }
        var result: [LogoShortcutAction:LogoShortcut] = [:]
        for action in LogoShortcutAction.allCases {
            if let data = defaults.data(forKey:action.preferenceKey) {
                do {
                    let decoded = try JSONDecoder().decode(LogoShortcut?.self,from:data)
                    if let decoded { try decoded.validate(); result[action] = decoded }
                    continue // A decoded null remains explicitly disabled.
                } catch { result[action] = action.defaultBinding; continue }
            }
            if action == .toggle, defaults.object(forKey:"shortcut.key") != nil,
                      let key = UInt32(exactly:defaults.integer(forKey:"shortcut.key")),
                      let modifiers = UInt32(exactly:defaults.integer(forKey:"shortcut.modifiers")) {
                let oldLabel = defaults.string(forKey:"shortcut.label") ?? "B"
                let label = String(oldLabel.drop(while:{"⌃⌥⇧⌘".contains($0)}))
                let binding = LogoShortcut(keyCode:key,modifiers:modifiers,keyLabel:label)
                result[action] = (try? binding.validate()) != nil ? binding : action.defaultBinding
            } else { result[action] = action.defaultBinding }
        }
        return result
    }
    static func save(_ binding: LogoShortcut?, action: LogoShortcutAction, defaults: UserDefaults) throws {
        if let binding { try binding.validate() }
        defaults.set(try JSONEncoder().encode(binding),forKey:action.preferenceKey)
        if action == .toggle, let binding {
            defaults.set(Int(binding.keyCode),forKey:"shortcut.key")
            defaults.set(Int(binding.modifiers),forKey:"shortcut.modifiers")
            defaults.set(binding.label,forKey:"shortcut.label")
        }
    }
}

enum LogoBrightnessStep {
    static func next(_ brightness: Double, action: LogoShortcutAction, mode: GlowMode) -> Double? {
        guard mode != .battery, brightness.isFinite, action != .toggle else { return nil }
        let percent = Effects.clamp(brightness) * 100 + (action == .increase ? 5 : -5)
        return min(100,max(0,percent)) / 100
    }
}

/// A failed replacement keeps the previous registration. Suspending for the
/// recorder releases keys, and dispatch ignores callbacks already in flight.
@MainActor final class LogoShortcutRegistry<Handle> {
    private(set) var desired: [LogoShortcutAction:LogoShortcut] = [:]
    private var active: [LogoShortcutAction:Handle] = [:]
    private(set) var suspended = false
    let register: (LogoShortcutAction,LogoShortcut) throws -> Handle
    let unregister: (Handle) -> Void
    init(register: @escaping (LogoShortcutAction,LogoShortcut) throws -> Handle, unregister: @escaping (Handle)->Void) {
        self.register = register; self.unregister = unregister
    }
    func configure(_ bindings: [LogoShortcutAction:LogoShortcut]) -> [LogoShortcutAction:String] {
        active.values.forEach(unregister); active.removeAll(); desired.removeAll(); suspended = false
        var issues: [LogoShortcutAction:String] = [:]
        for action in LogoShortcutAction.allCases {
            do { try replace(bindings[action],for:action) }
            catch { issues[action] = error.localizedDescription }
        }
        return issues
    }
    func replace(_ binding: LogoShortcut?, for action: LogoShortcutAction) throws {
        if let binding {
            try binding.validate()
            guard !desired.contains(where:{$0.key != action && $0.value.matches(binding)}) else {
                throw ShortcutError(message:"That combination is assigned to another Backlit action.")
            }
            if desired[action]?.matches(binding) == true, active[action] != nil { desired[action] = binding; return }
            let candidate = try register(action,binding)
            if let previous = active[action] { unregister(previous) }
            active[action] = candidate; desired[action] = binding
        } else {
            if let previous = active.removeValue(forKey:action) { unregister(previous) }
            desired.removeValue(forKey:action)
        }
    }
    func suspend() {
        guard !suspended else { return }
        suspended = true; active.values.forEach(unregister); active.removeAll()
    }
    func resume() -> [LogoShortcutAction:String] {
        suspended = false
        var issues: [LogoShortcutAction:String] = [:]
        for action in LogoShortcutAction.allCases where active[action] == nil {
            if let binding = desired[action] {
                do { active[action] = try register(action,binding) }
                catch { issues[action] = error.localizedDescription }
            }
        }
        return issues
    }
    func action(signature: OSType, id: UInt32) -> LogoShortcutAction? {
        guard !suspended, signature == LogoShortcutAction.signature,
              let action = LogoShortcutAction(rawValue:id), active[action] != nil else { return nil }
        return action
    }
}

/// Shared native-handler admission; nil means unregister/disable only.
@MainActor enum LogoShortcutChange {
    static func apply<Handle>(_ binding: LogoShortcut?, action: LogoShortcutAction,
                              registry: LogoShortcutRegistry<Handle>, ensureHandler: () throws -> Void) throws {
        if binding != nil { try ensureHandler() }
        try registry.replace(binding, for: action)
    }
}

@MainActor final class MacGlobalShortcuts {
    private static weak var receiver: MacGlobalShortcuts?
    private var handler: EventHandlerRef?
    private var unavailable: [LogoShortcutAction:String] = [:]
    var onAction: ((LogoShortcutAction)->Void)?
    private let registry = LogoShortcutRegistry<EventHotKeyRef>(register:{action,binding in
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(binding.keyCode,binding.modifiers,
            EventHotKeyID(signature:LogoShortcutAction.signature,id:action.rawValue),
            GetApplicationEventTarget(),UInt32(kEventHotKeyExclusive),&reference)
        guard result == noErr, let reference else {
            throw ShortcutError(message:"macOS could not register that shortcut (\(result)). Choose a different combination.")
        }
        return reference
    },unregister:{_ = UnregisterEventHotKey($0)})

    private func ensureHandler() throws {
        guard handler == nil else { return }
        var event = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),{_,event,_ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID(signature:0,id:0)
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),
                                    nil,MemoryLayout<EventHotKeyID>.size,nil,&identifier) == noErr,
                  identifier.signature == LogoShortcutAction.signature,
                  LogoShortcutAction(rawValue:identifier.id) != nil else { return OSStatus(eventNotHandledErr) }
            let signature = identifier.signature, id = identifier.id
            // Application-target Carbon handlers run on the GUI event loop.
            // Deliver synchronously so a queued old press cannot fire after
            // recording has closed and registrations have changed.
            return MainActor.assumeIsolated {
                guard let receiver = MacGlobalShortcuts.receiver,
                      let action = receiver.registry.action(signature:signature,id:id) else { return OSStatus(eventNotHandledErr) }
                receiver.onAction?(action)
                return noErr
            }
        },1,&event,nil,&handler)
        guard status == noErr else { throw ShortcutError(message:"macOS could not enable global shortcuts (\(status)).") }
        Self.receiver = self
    }
    func start(_ bindings: [LogoShortcutAction:LogoShortcut]) -> [LogoShortcutAction:String] {
        do { try ensureHandler(); unavailable = registry.configure(bindings) }
        catch { unavailable = Dictionary(uniqueKeysWithValues:bindings.keys.map{($0,error.localizedDescription)}) }
        return unavailable
    }
    func replace(_ binding: LogoShortcut?, action: LogoShortcutAction) -> String? {
        do {
            try LogoShortcutChange.apply(binding, action: action, registry: registry, ensureHandler: ensureHandler)
            unavailable.removeValue(forKey: action); return nil
        }
        catch { return error.localizedDescription }
    }
    func suspend() { registry.suspend() }
    func resume() -> [LogoShortcutAction:String] {
        let issues = registry.resume()
        for action in registry.desired.keys { unavailable[action] = issues[action] }
        return unavailable
    }
}
