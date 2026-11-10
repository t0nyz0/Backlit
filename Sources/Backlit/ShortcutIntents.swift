import AppIntents

// Native intent discovery/metadata extraction still needs a packaged-app check.
enum ShortcutBehavior:String,AppEnum {
    case steady,breathe,battery,music,agents,trackpad,signals
    static var typeDisplayRepresentation:TypeDisplayRepresentation {"Behavior"}
    static var caseDisplayRepresentations:[ShortcutBehavior:DisplayRepresentation] {
        [.steady:"Steady",.breathe:"Breathe",.battery:"Battery",.music:"Music",.agents:"Agents",.trackpad:"Trackpad",.signals:"Signals"]
    }
}

enum ShortcutActivity:String,AppEnum {
    case build,export,backup,focus,recording,streaming
    static var typeDisplayRepresentation:TypeDisplayRepresentation {"Activity"}
    static var caseDisplayRepresentations:[ShortcutActivity:DisplayRepresentation] {
        [.build:"Build",.export:"Export",.backup:"Backup",.focus:"Focus",.recording:"Recording",.streaming:"Streaming"]
    }
}

enum ShortcutActivityState:String,AppEnum {
    case active,complete,attention,clear
    static var typeDisplayRepresentation:TypeDisplayRepresentation {"Activity state"}
    static var caseDisplayRepresentations:[ShortcutActivityState:DisplayRepresentation] {
        [.active:"Active",.complete:"Complete",.attention:"Needs attention",.clear:"Clear"]
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

struct SendBacklightSignalIntent:AppIntent {
    static var title:LocalizedStringResource {"Send Backlight Signal"}
    static var openAppWhenRun:Bool {true}
    static var authenticationPolicy:IntentAuthenticationPolicy {.requiresLocalDeviceAuthentication}
    @Parameter(title:"Activity") var activity:ShortcutActivity
    @Parameter(title:"State") var state:ShortcutActivityState
    @Parameter(title:"Duration in seconds") var seconds:Double?
    @Parameter(title:"Progress from 0 to 1") var progress:Double?
    @MainActor func perform() async throws ->some IntentResult {
        guard let category=ActivityCategory(rawValue:activity.rawValue),let status=ActivityState(rawValue:self.state.rawValue) else {throw AutomationError.invalidSignal}
        let signal=try ActivitySignal(category:category,state:status,duration:seconds,progress:progress)
        try AutomationRouter.shared.perform(.signal(signal));return .result()
    }
}

struct BacklitShortcuts:AppShortcutsProvider {
    static var appShortcuts:[AppShortcut] {
        AppShortcut(intent:ToggleBacklightIntent(),phrases:["Toggle my backlight with \(.applicationName)"],shortTitle:"Toggle Backlight",systemImageName:"sun.max")
        AppShortcut(intent:SetBacklightBrightnessIntent(),phrases:["Set my backlight brightness with \(.applicationName)"],shortTitle:"Set Brightness",systemImageName:"sun.max.fill")
        AppShortcut(intent:SetBacklightBehaviorIntent(),phrases:["Set my backlight behavior with \(.applicationName)"],shortTitle:"Set Behavior",systemImageName:"slider.horizontal.3")
    }
}
