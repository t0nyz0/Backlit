import AppIntents

// Native intent discovery/metadata extraction still needs a packaged-app check.
enum ShortcutBehavior:String,AppEnum {
    case steady,breathe,battery,music,agents,trackpad,typing
    static var typeDisplayRepresentation:TypeDisplayRepresentation {"Behavior"}
    static var caseDisplayRepresentations:[ShortcutBehavior:DisplayRepresentation] {
        [.steady:"Steady",.breathe:"Breathe",.battery:"Battery",.music:"Music",.agents:"Agents",.trackpad:"Trackpad",.typing:"Typing"]
    }
}

struct ToggleBacklightIntent:AppIntent {
    static var title:LocalizedStringResource {"Toggle Backlight"}
    static var openAppWhenRun:Bool {true}
    static var authenticationPolicy:IntentAuthenticationPolicy {.requiresLocalDeviceAuthentication}
    @MainActor func perform() async throws ->some IntentResult {
        try AutomationRouter.shared.perform(.toggle);return .result()
    }
}

struct SetBacklightPowerIntent:AppIntent {
    static var title:LocalizedStringResource {"Set Backlight Power"}
    static var openAppWhenRun:Bool {true}
    static var authenticationPolicy:IntentAuthenticationPolicy {.requiresLocalDeviceAuthentication}
    @Parameter(title:"On") var enabled:Bool
    @MainActor func perform() async throws ->some IntentResult {
        try AutomationRouter.shared.perform(.power(enabled));return .result()
    }
}

struct SetBacklightBrightnessIntent:AppIntent {
    static var title:LocalizedStringResource {"Set Backlight Brightness"}
    static var openAppWhenRun:Bool {true}
    static var authenticationPolicy:IntentAuthenticationPolicy {.requiresLocalDeviceAuthentication}
    @Parameter(title:"Brightness",default:70) var percentage:Double
    @MainActor func perform() async throws ->some IntentResult {
        guard percentage.isFinite,(0...100).contains(percentage) else {throw AutomationError.invalidValue}
        try AutomationRouter.shared.perform(.brightness(percentage/100));return .result()
    }
}

struct SetBacklightBehaviorIntent:AppIntent {
    static var title:LocalizedStringResource {"Set Backlight Behavior"}
    static var openAppWhenRun:Bool {true}
    static var authenticationPolicy:IntentAuthenticationPolicy {.requiresLocalDeviceAuthentication}
    @Parameter(title:"Behavior") var behavior:ShortcutBehavior
    @MainActor func perform() async throws ->some IntentResult {
        try AutomationRouter.shared.perform(.mode(try AutomationCommand.behavior(named:behavior.rawValue)));return .result()
    }
}

struct BacklitShortcuts:AppShortcutsProvider {
    static var appShortcuts:[AppShortcut] {
        AppShortcut(intent:ToggleBacklightIntent(),phrases:["Toggle my backlight with \(.applicationName)"],shortTitle:"Toggle Backlight",systemImageName:"sun.max")
        AppShortcut(intent:SetBacklightBrightnessIntent(),phrases:["Set my backlight brightness with \(.applicationName)"],shortTitle:"Set Brightness",systemImageName:"sun.max.fill")
        AppShortcut(intent:SetBacklightBehaviorIntent(),phrases:["Set my backlight behavior with \(.applicationName)"],shortTitle:"Set Behavior",systemImageName:"slider.horizontal.3")
    }
}
