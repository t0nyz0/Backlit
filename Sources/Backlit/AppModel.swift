import AppKit
import SwiftUI
import ServiceManagement
import Combine
import OSLog

/// Pure decision seam for mode-driven capture; the existing driver still owns
/// asynchronous starts, cancellation and all operating-system authorization.
enum MusicCapturePolicy {
    enum Action: Equatable { case start, stop, none }
    static func action(mode: GlowMode, enabled: Bool, eligible: Bool,
                       preview: Bool, failed: Bool, active: Bool) -> Action {
        guard !preview, mode == .music, enabled, eligible else { return active ? .stop : .none }
        return !failed && !active ? .start : .none
    }
}

@MainActor final class LightPresentation: ObservableObject {
    @Published var level = 0.0
}

@MainActor final class AppModel: ObservableObject {
    struct MusicCaptureObservation {
        let deviceAvailable: Bool
        let locked: Bool
        let lidClosed: Bool
    }
    let updater = AppUpdater()
    let demo: Bool
    let defaults: UserDefaults
    @Published var menuBarIconVisible = true {
        didSet {
            guard !isLoading, menuBarIconVisible != oldValue else { return }
            defaults.set(menuBarIconVisible, forKey: "menuBarIcon.visible")
            onMenuBarIconVisibilityChange?()
        }
    }
    var onMenuBarIconVisibilityChange: (() -> Void)?
    let device: LogoDevice
    let audio = SystemAudio()
    let touch = TouchResponse()
    let typing = TypingInput()
    private let powerMonitor = PowerSourceMonitor()
    private var typingDown = false
    private var typingStartPolicy = TypingStartPolicy()
    var typingDriver: TypingDriver?
    private var touchWanted = false
    @Published var typingStatus = "Typing response is off"
    @Published var typingAccessFeedback: String?
    @Published var typingAccessCheck: TypingPermissionCheck?
    @Published var typingEnabled = false {
        didSet { guard !isLoading else { return }; defaults.set(typingEnabled, forKey: "typing.enabled"); synchronizeTyping() }
    }
    @Published var musicAutomatic = true { didSet { guard !isLoading else { return }; musicResponse.reset(); save(); requestFrame() } }
    @Published var musicPreset: MusicResponsePreset = .balanced { didSet { guard !isLoading else { return }; musicResponse.reset(); save(); requestFrame() } }
    @Published var batteryOptions = BatteryResponseOptions() {
        didSet {
            guard !isLoading else { return }
            if let data = try? JSONEncoder().encode(batteryOptions) { defaults.set(data, forKey: "battery.response") }
            requestFrame()
        }
    }
    @Published var batteryAvailable = false
    @Published var chargeReady = false
    @Published var automationsEnabled = false {
        didSet {
            guard !isLoading else { return }
            defaults.set(automationsEnabled, forKey: "automation.enabled")
            AutomationRouter.shared.enabled = automationsEnabled && !demo
            requestFrame()
        }
    }
    private var batteryResponse = BatteryResponse()
    private var musicResponse = MusicResponse()
    let touchSources = TouchResponse.sources
    var touchAvailable:Bool {!touchSources.isEmpty || typingEnabled}
    @Published var touchSource:TouchSource = .screen {didSet {
        guard !isLoading else{return};defaults.set(touchSource.rawValue,forKey:"touch.source")
        synchronizeTouch(forceRestart: true)
    }}
    @Published var touchClickBlink = false {didSet {if !isLoading {defaults.set(touchClickBlink,forKey:"touch.clickBlink")}}}
    private var touchBlinking = false
    private var blinkGeneration = 0
    @Published var touchDown = false
    @Published var touchStatus = "Waiting for touch"
    var availableModes:[GlowMode] {GlowMode.allCases.filter{$0 != .touch || touchAvailable}}
    let bridge = HomeBridge()
    @Published var mode: GlowMode = .battery { didSet { guard !isLoading else{return}; lastSourceSample = -Double.infinity; if mode == .battery {lastBatterySample = -Double.infinity}; save(); if mode != .music { stopAudio() } else if oldValue != .music { clearAudioFailure() }
        synchronizeTouch()
        batteryResponse.reset(); musicResponse.reset(); synchronizeTyping(); configureTimer(); requestFrame() } }
    @Published var enabled = true { didSet {
        guard !isLoading else{return}
        if !enabled { invalidateLightReadyNotice() }
        defaults.set(enabled,forKey:"enabled")
        if !ambientChangeInProgress && !demo && device.available && !device.needsRecovery { controlWanted = true }
        synchronizeTouch()
        if !enabled && (audioRunning || audioStarting) {stopAudio()}
        synchronizeTyping(); requestFrame(); configureTimer()
    } }
    @Published var brightness = 0.68 { didSet { save(); requestFrame() } }
    @Published var period = 6.0 { didSet { save(); requestFrame() } }
    @Published var intensity = 1.0 { didSet { save(); requestFrame() } }
    var musicIntensityPosition: Double {
        get { MusicIntensity.position(for: intensity) }
        set { intensity = MusicIntensity.multiplier(at: newValue) }
    }
    @Published var strobe = false { didSet { save(); requestFrame() } }
    @Published var controlWanted = false
    @Published var controlling = false
    let presentation = LightPresentation()
    private(set) var output = 0.0
    @Published var battery = 0.0
    @Published var activelyCharging = false
    @Published var charging = false
    var batteryIsPulsing: Bool { batteryAvailable && charging && activelyCharging && battery < 1 && batteryOptions.chargingStyle == .breathe && BatteryResponseOptions.bound(batteryOptions.pulseMinimum, 0...1, fallback: 0) < 1 }
    var batteryPowerLabel: String {
        guard batteryAvailable else { return "Battery state unavailable" }
        if !charging { return "On battery" }
        if battery >= 1 { return "Fully charged" }
        return activelyCharging ? "Charging" : "Plugged in · Not charging"
    }
    func updateBattery(_ snapshot: RuntimeServices.BatterySnapshot?) {
        let level = snapshot?.level ?? 0, external = snapshot?.externalPower ?? false
        let active = snapshot?.activelyCharging ?? false, available = snapshot != nil
        if battery != level { battery = level }
        if charging != external { charging = external }
        if activelyCharging != active { activelyCharging = active }
        if batteryAvailable != available { batteryAvailable = available }
    }
    @Published var agents: [AgentEvent] = []
    @Published var audioRunning = false
    @Published var audioPermissionHelp = false
    @Published private(set) var audioCaptureError: String?
    @Published var audioStarting = false
    @Published private(set) var audioStopping = false
    @Published var keepClosed = false
    @Published private(set) var lidRequested = false
    @Published private(set) var lidPreferenceStatus = "Off"
    private let lidIntentController: LidIntentController
    private let lidIntentEnvironment: LidIntentEnvironment?
    private var lastLidIntentCheck = -Double.infinity
    private var lastHardwareResult: FadeApplyResult?
    private var lidOffPending = false
    @Published private(set) var lidSessionDuration = LidSessionDuration() {
        didSet {
            guard !isLoading, let data = try? JSONEncoder().encode(lidSessionDuration) else { return }
            defaults.set(data, forKey: LidSessionDuration.preferenceKey)
        }
    }
    var canEditLidDuration: Bool { !lidRequested && watcher == nil && !lidStopPending && !lidStopper.hasOutstandingFilesystemWork }
    @Published var ambientUnlocked = false
    @Published var bridgeEnabled = false
    @Published var bridgeLAN = false
    @Published var bridgeStatus = "Not connected"
    @Published var language = "en" { didSet { save() } }
    @Published var appearance = "system" { didSet { save() } }
    @Published var error: String?
    @Published private(set) var hardwareFailure: String?
    @Published private var storedNotice: String?
    var notice: String? {
        get { storedNotice == Self.lightReadyNotice && !lightReady ? nil : storedNotice }
        set { storedNotice = newValue }
    }
    private static let lightReadyNotice = "Your light is ready."
    /// Ownership and cleanup completion alone do not establish output readiness.
    var lightReady: Bool {
        (!demo || hardwareApply != nil) && enabled && controlWanted && controlling &&
            lastHardwareResult == .applied && hardwareFailure == nil && pausedReason == nil &&
            lifecycleAllowsFrames && !systemSleeping && !cachedLocked && consoleActive &&
            (!screenSleeping || (cachedLid && keepClosed)) && !automaticRecoveryPending &&
            !reconnecting && !lidStopPending && !lidStopper.hasOutstandingFilesystemWork &&
            lidIntentController.intent?.blocked != true && lidIntentController.intent?.savedPause == nil
    }
    func announceLightReadiness() {
        if lightReady { notice = Self.lightReadyNotice }
        else { invalidateLightReadyNotice() }
    }
    private func invalidateLightReadyNotice() {
        if storedNotice == Self.lightReadyNotice { storedNotice = nil }
    }
    @Published var pausedReason: String?
    @Published var shortcutKey: UInt32 = 11
    @Published var shortcutModifiers: UInt32 = 4352
    @Published var shortcutLabel = "⌃⌘B"
    @Published var selectedPage = "light"
    var openWindow: (() -> Void)?
    var onIconChange: (() -> Void)?
    var isPreviewVisible:(()->Bool)?
    var visualUpdatesAllowed: Bool {
        VisualUpdatePolicy.allows(locked: cachedLocked, screenSleeping: screenSleeping,
                                  systemSleeping: systemSleeping, consoleActive: consoleActive)
    }
    private var isLoading = true
    private var timer: Timer?
    private var terminationApproved = false
    private let quitRunLoop = QuitRunLoop()
    private var isStopping = false
    private(set) var hardwareRecoveryInProgress = false
    private(set) var hardwareApplyInProgress = false
    var hardwareOperationInProgress: Bool { hardwareRecoveryInProgress || hardwareApplyInProgress || ambientAuthorizationInProgress }
    private(set) var lidCleanupInProgress = false
    var lifecycleAllowsFrames: Bool { !isStopping && !hardwareOperationInProgress && !savedLidCheckInProgress && !lidCleanupInProgress && !lidStopFailed }
    private let hardwareRestore: (() throws -> Void)?
    private let hardwareApply: ((Double, Bool) throws -> FadeApplyResult)?
    private let ambientAuthorization: ((Bool) throws -> Void)?
    private var ambientChangeInProgress = false
    private var ambientAuthorizationInProgress = false
    private var ambientResumeAllowed = false
    private let lidPauseRecoveryEnvironment: LidPauseRecoveryEnvironment?
    private var savedLidRecoveryAllowed = true
    private var savedLidCheckInProgress = false
    private var controlOffPending = false
    private let recoveryLogger = Logger(subsystem: "local.backlit", category: "recovery")
    @Published private(set) var reconnecting = false
    private struct PendingLifecycleRecovery {
        var attempts = 0
        var retryAt: Double
        let message: String
    }
    private var pendingLifecycleRecovery: PendingLifecycleRecovery?
    var recoveryClock: () -> Double = { ProcessInfo.processInfo.systemUptime }
    var automaticRecoveryPending: Bool { pendingLifecycleRecovery != nil }
    private var lifecycleInterrupted: Bool { systemSleeping || screenSleeping || cachedLocked || !consoleActive }
    private var tickCount = 0
    private var lastSourceSample = -Double.infinity
    private var lastBatterySample = -Double.infinity
    private var lastAgentPrune = -Double.infinity
    private var lastPreviewSample = -Double.infinity
    private var timerInterval = 0.0
    private var framePending = false
    private var competingController: String?
    private var cachedLogoEnabled: Bool?
    var logoStatus: LogoStatus {
        LogoStatus(requested: output, hardwareEnabled: cachedLogoEnabled,
                   controlling: controlling, lidClosed: cachedLid, preview: demo)
    }
    private var cachedLid = false
    private var cachedLocked = false
    private var cachedAway = false
    private var audioConsent = false
    private var musicHardwareReady = false
    private let musicCaptureObservation: (() -> MusicCaptureObservation)?
    private lazy var audioSession = AudioSessionDriver(
        start: { [audio = self.audio] in try await audio.start() },
        stop: { [audio = self.audio] in await audio.stop() },
        eligible: { [weak self] in
            guard let self else { return false }
            return !self.demo && self.musicCaptureAllowed
        },
        changed: { [weak self] state in
            guard let self else { return }
            self.audioStarting = state == .starting
            self.audioRunning = state == .running
            self.audioStopping = state == .stopping
            if state == .running { self.audioConsent = true }
            self.requestFrame()
        },
        failed: { [weak self] error in
            guard let self else { return }
            self.audioPermissionHelp = true
            self.audioCaptureError = SystemAudio.friendly(error).localizedDescription
            self.error = self.audioCaptureError
            self.requestFrame()
        })
    private var screenSleeping = false
    private var systemSleeping = false
    private var consoleActive = true
    private var watcher: (any LidWatcherProcess)?
    private let lidStopper: LidWatcherStopper
    @Published private(set) var lidStopPending = false
    var onLidStopCompleted: ((Bool) -> Void)?
    private var lidStopFailed = false
    private var lease: URL?
    private var observers: [NSObjectProtocol] = []
    private let epoch = ProcessInfo.processInfo.systemUptime
    var id: String { defaults.string(forKey:"installation.id")! }
    var agentState: AgentState { AgentBridge.aggregate(agents) }
    var isChinese: Bool { language == "zh-Hant" }
    var savedLidPauseNeedsReview: Bool {
        lidIntentController.intent?.savedPause.map { $0.needsQualifiedHandback || !$0.canRetry } == true
    }
    var savedLidRecoveryUnconfirmed: Bool { lidIntentController.intent?.savedPause?.needsQualifiedHandback == true }
    func t(_ english: String, _ chinese: String) -> String { isChinese ? chinese : english }
    var status: String {
        if automaticRecoveryPending || reconnecting { return lifecycleInterrupted ? "Waiting to reconnect after wake" : "Reconnecting to your MacBook" }
        if let hardwareFailure { return "Logo control unavailable: \(hardwareFailure)" }
        if let pausedReason { return pausedReason }
        // Explain a saved safety pause without turning it into a runtime pause
        // or hiding a current pause or the user's explicit Off choice.
        if (!demo || hardwareApply != nil), enabled, let pause = lidIntentController.intent?.savedPause {
            if pause.needsQualifiedHandback { return pause.status }
            return cachedLid ? "Closed-lid lighting paused after an error" : pause.status
        }
        if demo { return t("Preview · logo unchanged","預覽・不會更改標誌") }
        if !device.available { return t("Preview · compatible logo not found","預覽・未找到相容標誌") }
        if !controlWanted && device.needsRecovery { return "Restore your light to continue" }
        if !enabled { return t("Logo off","標誌已關閉") }
        guard controlling else { return "Connecting to your MacBook" }
        switch lastHardwareResult {
        case .waiting: return "Waiting for light output"
        case .paused: return "Light output paused"
        case nil: return "Connecting to your MacBook"
        case .applied: break
        }
        if let label = logoStatus.statusLabel { return label }
        switch mode {
        case .steady:return t("Glowing","發光中")
        case .breathe:return t("Breathing","呼吸中")
        case .battery:
            if !batteryAvailable { return "Battery state unavailable" }
            if batteryResponse.completionActive { return "Charge-ready signal" }
            if batteryIsPulsing { return "Pulsing while charging" }
            if charging && batteryOptions.chargingStyle != .level { return "Steady while plugged in" }
            return t("Following your battery","跟隨電量")
        case .music:return audioRunning ? "Moving with your music" : "Ready for your music"
        case .agents:return "Watching your agents"
        case .touch:return touchDown || typingDown ? "Input active · light on" : typingEnabled ? "Ready for trackpad or typing" : "Ready for \(touchSource.title.lowercased()) touch"
        case .typing:return typingDown ? "Typing active · light on" : typingStatus
        }
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    init(demo: Bool = false, defaults: UserDefaults? = nil, lidStopper: LidWatcherStopper? = nil,
         musicCaptureObservation: (() -> MusicCaptureObservation)? = nil,
         hardwareRestore: (() throws -> Void)? = nil, lidIntentEnvironment: LidIntentEnvironment? = nil,
         hardwareApply: ((Double, Bool) throws -> FadeApplyResult)? = nil,
         lidPauseRecoveryEnvironment: LidPauseRecoveryEnvironment? = nil,
         ambientAuthorization: ((Bool) throws -> Void)? = nil) {
        self.hardwareRestore = hardwareRestore
        self.hardwareApply = hardwareApply
        self.ambientAuthorization = ambientAuthorization
        self.lidPauseRecoveryEnvironment = lidPauseRecoveryEnvironment
        self.lidIntentEnvironment = lidIntentEnvironment
        self.musicCaptureObservation = musicCaptureObservation
        self.lidStopper = lidStopper ?? LidWatcherStopper()
        self.demo = demo
        self.defaults = defaults ?? (demo ? UserDefaults(suiteName:(Bundle.main.bundleIdentifier ?? "local.backlit") + ".preview")! : .standard)
        LidSessionIntent.migrateStoredDuration(self.defaults)
        lidIntentController = LidIntentController(defaults: self.defaults)
        let requested = lidIntentController.intent != nil
        lidRequested = requested
        lidPreferenceStatus = lidIntentController.intent?.savedPause?.status ??
            (requested ? "Remembered. Waiting for your Mac and light to be ready." : "Off")
        if let visible = self.defaults.object(forKey: "menuBarIcon.visible") as? Bool { menuBarIconVisible = visible }
        if let data = self.defaults.data(forKey: LidSessionDuration.preferenceKey),
           let duration = try? JSONDecoder().decode(LidSessionDuration.self, from: data) {
            lidSessionDuration = duration
            // Persist the normalized cap without changing unrelated settings.
            if let normalized = try? JSONEncoder().encode(duration) { self.defaults.set(normalized, forKey: LidSessionDuration.preferenceKey) }
        }
        device = LogoDevice(directory:AgentBridge.directory)
        if let raw = self.defaults.string(forKey: "mode") {
            if raw == "signals" {
                mode = .battery
                self.defaults.set(GlowMode.battery.rawValue, forKey: "mode")
            } else if let mode = GlowMode(rawValue: raw) { self.mode = mode }
        }
        if self.defaults.object(forKey:"brightness") != nil { brightness = self.defaults.double(forKey:"brightness") }
        if self.defaults.object(forKey:"period") != nil { period = self.defaults.double(forKey:"period") }
        if self.defaults.object(forKey:"intensity") != nil { intensity = self.defaults.double(forKey:"intensity") }
        if let raw=self.defaults.string(forKey:"touch.source"),let source=TouchSource(rawValue:raw),touchSources.contains(source) {touchSource=source}
        else {touchSource=touchSources.first ?? .screen}
        touchClickBlink = self.defaults.bool(forKey:"touch.clickBlink")
        strobe = self.defaults.bool(forKey:"strobe")
        typingEnabled = self.defaults.bool(forKey: "typing.enabled")
        if mode == .touch && !touchAvailable { mode = .steady }
        automationsEnabled = self.defaults.bool(forKey: "automation.enabled")
        if self.defaults.object(forKey: "music.automatic") != nil { musicAutomatic = self.defaults.bool(forKey: "music.automatic") }
        if let raw = self.defaults.string(forKey: "music.preset"), let preset = MusicResponsePreset(rawValue: raw) { musicPreset = preset }
        if let data = self.defaults.data(forKey: "battery.response"), let options = try? JSONDecoder().decode(BatteryResponseOptions.self, from: data) { batteryOptions = options }
        if self.defaults.object(forKey:"enabled") != nil { enabled = self.defaults.bool(forKey:"enabled") }
        language = self.defaults.string(forKey:"language") ?? "en"
        appearance = self.defaults.string(forKey:"appearance") ?? "system"
        if self.defaults.string(forKey:"installation.id") == nil { self.defaults.set(UUID().uuidString,forKey:"installation.id") }
        if self.defaults.object(forKey:"shortcut.key") != nil {
            shortcutKey = UInt32(self.defaults.integer(forKey:"shortcut.key"))
            shortcutModifiers = UInt32(self.defaults.integer(forKey:"shortcut.modifiers"))
            shortcutLabel = self.defaults.string(forKey:"shortcut.label") ?? "⌃⌘B"
        }
        ambientUnlocked = self.defaults.bool(forKey:"ambientUnlocked")
        touch.onChange = { [weak self] down,count in
            guard let self else{return}
            self.touchDown=down
            self.touchStatus=self.touch.eventCount == 0 ? "Waiting for \(self.touchSource.title.lowercased()) touch" : (down ? "Touch detected · hold to keep lit" : "Touch released · light off")
            if self.mode == .touch {self.cachedLocked=RuntimeServices.locked;self.requestFrame()}
        }
        touch.onClick = { [weak self] in
            guard let self,self.mode == .touch,self.enabled,self.touchClickBlink,self.touchDown,self.touchSource != .screen else{return}
            self.blinkGeneration += 1;let generation=self.blinkGeneration
            self.touchBlinking=true;self.tick()
            DispatchQueue.main.asyncAfter(deadline:.now()+0.09) { [weak self] in
                guard let self,self.blinkGeneration == generation else{return}
                self.touchBlinking=false;self.tick()
            }
        }
        typing.onActivity = { [weak self] active in
            guard let self else { return }
            if active && RuntimeServices.locked {
                self.cachedLocked = true
                self.typing.stop()
                self.typingStartPolicy = TypingStartPolicy()
                return
            }
            self.typingDown = active
            self.requestFrame()
        }
        typing.onStatus = { [weak self] status in self?.typingStatus = status }
        audio.onFailure = { [weak self] text, token in Task { @MainActor in
            guard let self, self.audioRunning, self.audio.acceptsFailure(token) else { return }
            self.audioSession.requestStop()
            self.audioRunning = false; self.audioPermissionHelp = true
            self.audioCaptureError = text; self.error = text; self.requestFrame()
        } }
        bridge.state = { [weak self] in self?.apiState() ?? [:] }
        bridge.command = { [weak self] command in
            guard let self else { return }
            guard self.controlling, self.pausedReason == nil else { throw RuntimeServices.failure("Open Backlit on the Mac and restore its light if a recovery message is shown.") }
            if command.mode == .music && !self.audioConsent { throw RuntimeServices.failure("Select Music in Backlit and allow system audio before selecting it remotely.") }
            if let mode = command.mode { guard self.availableModes.contains(mode) else { throw RuntimeServices.failure("That mode is unavailable on this Mac.") }; self.mode = mode }
            if let brightness = command.brightness { self.brightness = brightness }
            if let enabled = command.enabled { self.enabled = enabled }
            self.tick()
        }
        bridge.onStatus = { [weak self] text in self?.bridgeStatus = text }
        self.lidStopper.onResult = { [weak self] result in
            guard let self else { return }
            self.lidStopFailed = !result.safeToQuit
            var safe = result.safeToQuit
            if result.safeToQuit {
                self.watcher = nil; self.lease = nil
                if result.leaseRemovalError != nil { self.notice = "Normal lid sleep was restored. A leftover session file could not be removed." }
                // The lid helper may have triggered fade recovery. Retire that
                // session before another frame or the pending quit can proceed.
                do { if self.controlling { try self.restoreOwnedHardware() } }
                catch {
                    self.error = error.localizedDescription; safe = false
                    if !self.isStopping && self.controlWanted && self.lifecycleInterrupted {
                        self.deferLifecycleRecovery(error)
                    }
                }
            } else {
                self.error = "Closed-lid cleanup could not be confirmed. Review power recovery in Settings, then retry."
            }
            self.lidStopPending = false
            self.lidCleanupInProgress = false
            if !safe && (!self.automaticRecoveryPending || !result.safeToQuit) {
                self.pendingLifecycleRecovery = nil
                self.lidIntentController.block(); self.controlWanted = false; self.cancelStopping()
                self.lidPreferenceStatus = "Paused after an error. Restore your light before retrying."
            } else if self.lidRequested { self.lidPreferenceStatus = "Remembered. Waiting for your Mac and light to be ready." }
            self.lastLidIntentCheck = -Double.infinity
            if !self.isStopping { self.configureTimer(); self.requestFrame() }
            self.onLidStopCompleted?(safe)
        }
        isLoading = false
    }
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let states: [(Notification.Name,(AppModel)->Void)] = [
            (NSWorkspace.screensDidSleepNotification,{$0.screenSleeping = true;$0.touch.reset()}),
            (NSWorkspace.screensDidWakeNotification,{$0.screenSleeping = false;$0.touch.reset()}),
            (NSWorkspace.willSleepNotification,{$0.systemSleeping = true; $0.touch.reset(); $0.stopAudio(); $0.stopLid(); $0.releaseHardware()}),
            (NSWorkspace.didWakeNotification,{$0.systemSleeping = false;$0.touch.reset()}),
            (NSWorkspace.sessionDidResignActiveNotification,{$0.consoleActive = false; $0.touch.reset(); $0.stopAudio(); $0.releaseHardware()}),
            (NSWorkspace.sessionDidBecomeActiveNotification,{$0.consoleActive = true;$0.touch.reset()})
        ]
        for (name,action) in states { observers.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task { @MainActor in if let self { action(self); self.lastSourceSample = -Double.infinity; self.synchronizeTouch(); self.synchronizeTyping(); self.requestFrame() } }}) }
        controlWanted = !demo && device.available && !device.needsRecovery
        configureTimer()
        if !demo && !controlWanted && device.needsRecovery { notice = "A previous logo session needs restoration. Use Restore Light to pick up where you left off." }
        if !demo && self.defaults.bool(forKey:"bridge.enabled") { configureBridge(enabled:true,lan:self.defaults.bool(forKey:"bridge.lan")) }
        startPowerMonitoring()
        if !demo {
            // Before the first tick can create a session: leftovers from
            // earlier runs only. Recovery journals are never touched.
            SupportFilePruner.pruneFadeLeases()
            SupportFilePruner.pruneLidTimers(keeping: lidIntentController.intent?.id)
            pruneAgentFiles()
        }
        // The first tick samples lock/power/ownership policy before either
        // input monitor can register. All starts go through synchronization.
        tick()
    }
    /// Stale agent files are removed off the main thread; the reader already
    /// ignores them, so timing here is not important.
    private func pruneAgentFiles() {
        lastAgentPrune = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .utility).async {
            SupportFilePruner.pruneAgentEvents()
            SupportFilePruner.pruneAgentBackups()
        }
    }
    func save() {
        guard !isLoading else{return}
        defaults.set(mode.rawValue,forKey:"mode"); defaults.set(brightness,forKey:"brightness")
        defaults.set(period,forKey:"period"); defaults.set(intensity,forKey:"intensity"); defaults.set(strobe,forKey:"strobe")
        defaults.set(language,forKey:"language"); defaults.set(appearance,forKey:"appearance")
        defaults.set(musicAutomatic, forKey: "music.automatic")
        defaults.set(musicPreset.rawValue, forKey: "music.preset")
    }
    func tick() {
        defer { if !lightReady { invalidateLightReadyNotice() } }
        guard lifecycleAllowsFrames else { return }
        if controlOffPending { controlOffPending = false; stopLid(); releaseHardware(); return }
        if lidOffPending { stopLid(); return }
        if let watcher, !watcher.isRunning, !lidStopPending { stopLid(); return }
        tickCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now-lastSourceSample >= 1 {
            lastSourceSample = now
            competingController = demo ? nil : device.competingApp
            if now-lastBatterySample >= 15 {
                lastBatterySample=now
                updateBattery(demo ? .init(level: 0.82, externalPower: false, activelyCharging: false) : RuntimeServices.batterySnapshot())
                if !batteryAvailable { batteryResponse.reset() }
            }
            if !demo && now-lastAgentPrune >= 600 { pruneAgentFiles() }
            if mode == .agents || bridgeEnabled {
                let nextAgents=demo ? [] : AgentBridge.events().sorted{$0.time<$1.time}
                if agents != nextAgents {agents=nextAgents}
            }
            cachedLid = demo ? false : RuntimeServices.lidClosed
            cachedLogoEnabled = demo ? nil : LogoDevice.enabledState()
            cachedLocked = demo ? false : RuntimeServices.locked
            cachedAway = demo ? false : RuntimeServices.away
        }
        if let lidIntentEnvironment {
            cachedLid = lidIntentEnvironment.closed() ?? false
            cachedLocked = !lidIntentEnvironment.safety().unlocked
        }
        // This must precede begin/apply: begin itself creates an owned journal,
        // and no new effect may run while old cleanup remains unverified.
        recoverSavedLidPause()
        synchronizeLidIntent(preflightOnly: true)
        guard lifecycleAllowsFrames else { return }
        // A remembered choice can prepare ownership while closed; the helper
        // itself still waits for fresh safety checks and its original deadline.
        let allowClosed = cachedLid && (keepClosed || (lidRequested && lidIntentController.intent?.blocked == false && !cachedLocked))
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        var nextPause: String?
        if systemSleeping { nextPause = "Mac is sleeping" }
        else if let competingController { nextPause = "Quit \(competingController) to use Backlit" }
        else if !consoleActive { nextPause = "User session inactive" }
        else if ProcessInfo.processInfo.thermalState == .critical { nextPause = "Paused while your Mac cools down" }
        else if (!demo || hardwareApply != nil) && mode != .agents && !allowClosed && (screenSleeping || cachedLocked) { nextPause = "Paused with your display" }
        else if (!demo || hardwareApply != nil) && lowPower && mode != .agents && mode != .battery { nextPause = "Paused in Low Power Mode" }
        else { nextPause = nil }
        if pausedReason != nextPause {
            pausedReason = nextPause
        }
        synchronizeTouch()
        synchronizeTyping()
        if nextPause != nil && touchDown { touch.reset() }
        let nextOutput = effectOutput(at: now)
        output = nextOutput
        let presentedOutput = logoStatus.level
        if visualUpdatesAllowed && (isPreviewVisible?() != false) && now-lastPreviewSample >= 0.1 && abs(presentation.level-presentedOutput) > 0.005 { presentation.level = presentedOutput; lastPreviewSample = now }
        // Capture pauses independently of hardware ownership: losing the
        // device must not keep audio active after display sleep or lock.
        if pausedReason != nil && (audioRunning || audioStarting) { stopAudio() }
        if controlWanted && (!demo || hardwareApply != nil) {
            if pausedReason != nil { releaseHardware() }
            else if resumeAfterLifecycleRecovery() && lidIntentController.intent?.blocked != true {
                do {
                    try withHardwareApply {
                        try updateMusicHardwareReadiness {
                            if let hardwareApply { controlling = true; return try hardwareApply(output, keepClosed) }
                            if !controlling { try device.begin(); controlling = true }
                            return try device.apply(output, closedLid: keepClosed, frameInterval: EffectCadence.animationInterval(for:mode))
                        }
                    }
                    hardwareFailure = nil
                } catch { hardwareFailure = error.localizedDescription; self.error = error.localizedDescription; lidIntentController.block(); controlWanted = false; stopLid(); releaseHardware() }
            }
        }
        reconnecting = controlWanted && (automaticRecoveryPending || device.automaticRecoveryPending)
        synchronizeTouch(); synchronizeTyping()
        synchronizeLidIntent()
        // Capture starts only after ownership and the first output request
        // succeed, and stops if that work failed or the session became unsafe.
        synchronizeMusicCapture()
        onIconChange?()
        configureTimer()
    }
    func effectOutput(at now: Double) -> Double {
        var input = EffectInput()
        input.mode = mode; input.enabled = enabled; input.brightness = brightness; input.period = period
        input.battery = batteryAvailable ? battery : 0
        if mode == .battery && enabled && pausedReason == nil && batteryAvailable {
            input.battery = batteryResponse.update(charge: battery, externalPower: charging, at: now, options: batteryOptions, activelyCharging: activelyCharging)
        } else { batteryResponse.reset() }
        if chargeReady != batteryResponse.ready { chargeReady = batteryResponse.ready }
        if mode == .music && (audioRunning || demo) {
            let energy = demo ? 0.35 + 0.35 * sin((now - epoch) * 5) : audio.level
            input.audio = musicResponse.update(energy: energy, at: now, automatic: musicAutomatic, preset: musicPreset)
        }
        input.intensity = intensity; input.strobe = strobe
        input.agent = agentState; input.away = cachedAway
        input.touchDown = (touchDown && !touchBlinking) || typingDown
        input.typingDown = typingDown
        return pausedReason == nil ? Effects.level(at: now - epoch, input: input) : 0
    }
    func requestFrame() {
        guard !framePending else { return }
        framePending = true
        DispatchQueue.main.async { [weak self] in self?.framePending=false;self?.tick() }
    }
    func configureTimer() {
        guard lifecycleAllowsFrames else { timer?.invalidate(); return }
        let animated = pausedReason == nil && (device.closedEffectNeedsAnimation || (enabled && (mode == .breathe || (mode == .music && (audioRunning || demo)) || (mode == .agents && agentState != .waiting) || (mode == .battery && batteryResponse.requiresAnimation))))
        let interval = animated ? EffectCadence.animationInterval(for:mode) : 1.0
        guard timerInterval != interval || timer?.isValid != true else { return }
        timer?.invalidate(); timerInterval = interval
        let next=Timer(timeInterval:interval,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
        next.tolerance=animated ? min(0.005,interval*0.06) : 0.1
        RunLoop.main.add(next,forMode:.common);timer=next
    }
    var inputSessionEligible: Bool {
        let allowedClosed = keepClosed && cachedLid
        return lifecycleAllowsFrames && !automaticRecoveryPending && !reconnecting && controlWanted && (mode == .touch || mode == .typing) && enabled &&
            pausedReason == nil && !cachedLocked && !systemSleeping && consoleActive &&
            (!screenSleeping || allowedClosed)
    }
    private func synchronizeTouch(forceRestart: Bool = false) {
        let shouldRun = !demo && mode == .touch && inputSessionEligible
        let previous = touchWanted
        touchWanted = shouldRun
        if shouldRun && (!previous || forceRestart) {
            touchStatus = touch.start(source: touchSource) ? "Ready for trackpad contact" : "Trackpad events are unavailable on this macOS build"
        } else if !shouldRun && previous { touch.stop() }
    }
    private func startPowerMonitoring() {
        guard !demo else { return }
        powerMonitor.start { [weak self] in
            self?.lastBatterySample = -Double.infinity
            self?.lastSourceSample = -Double.infinity
            self?.requestFrame()
        }
    }
    func synchronizeTyping(forceRestart: Bool = false) {
        let shouldRun = !demo && typingInputEligible
        let driver = demo ? typingDriver : nil
        let eligible = driver?.eligible() ?? shouldRun
        let action = typingStartPolicy.action(eligible: eligible, force: forceRestart,
            now: driver?.now() ?? ProcessInfo.processInfo.systemUptime,
            permission: { driver?.permission() ?? self.typing.permissionGranted })
        if action == .start {
            if let driver { _ = driver.start() } else { _ = typing.start() }
        } else if action == .stop {
            if driver?.running() ?? typing.running {
                if let driver { driver.stop() } else { typing.stop() }
            }
            typingDown = false
            typingStatus = eligible ? "Input Monitoring permission is required for typing response" : "Typing response is off"
        }
        if !eligible { typingDown = false }
    }
    var typingInputEligible: Bool {
        inputSessionEligible && (mode == .typing || (mode == .touch && typingEnabled))
    }
    /// Deliberate access action shared by the standalone behavior and Trackpad option.
    func retryTypingAccess() {
        guard !demo else { notice = "Typing input is disabled in preview."; return }
        let check = typing.requestPermissionCheck()
        typingAccessCheck = check
        typingAccessFeedback = check.diagnostic
        guard check.after else {
            typingStatus = typing.status
            return
        }
        guard typingInputEligible else {
            typingAccessFeedback = check.diagnostic + " Typing is paused: \(pausedReason ?? (!enabled ? "turn the logo on" : "select Typing with the Mac awake, unlocked and light control active"))."
            return
        }
        synchronizeTyping(forceRestart: true)
        typingAccessFeedback = check.diagnostic + " " + typing.status
    }
    /// Supply synthetic state only in previews/tests, without registering input taps.
    func setPreviewInput(typing: Bool, blinking: Bool, away: Bool) {
        guard demo else { return }
        typingDown = typing; touchBlinking = blinking; cachedAway = away
    }
    func setPreviewInputSession(lidClosed: Bool, locked: Bool = false,
                                screenAsleep: Bool, systemAsleep: Bool = false,
                                sessionActive: Bool = true) {
        guard demo else { return }
        cachedLid = lidClosed; cachedLocked = locked; screenSleeping = screenAsleep
        systemSleeping = systemAsleep; consoleActive = sessionActive
    }
    func setTypingEnabled(_ enabled: Bool) {
        guard !demo else { notice = "Typing input is disabled in preview."; return }
        if enabled && !typing.permissionGranted { _ = typing.requestPermission() }
        let restart = typingEnabled == enabled
        typingEnabled = enabled
        if restart { synchronizeTyping(forceRestart: enabled) }
    }
    func performAutomation(_ command: AutomationCommand) throws {
        guard automationsEnabled, !demo else { throw RuntimeServices.failure("Enable Backlit links and other apps in Connections first.") }
        guard device.available, controlWanted, !device.needsRecovery else { throw RuntimeServices.failure("Open Backlit and restore its light before using external controls.") }
        switch command {
        case .power(let on): enabled = on
        case .toggle: enabled.toggle()
        case .brightness(let level):
            guard level.isFinite, (0...1).contains(level) else { throw RuntimeServices.failure("Brightness must be between 0 and 100 percent.") }
            brightness = level
        case .mode(let selected):
            guard availableModes.contains(selected) else { throw RuntimeServices.failure("That behavior is unavailable on this Mac.") }
            mode = selected
        }
        tick()
    }
    func repairAndResume() {
        guard !hardwareOperationInProgress else { return }
        pendingLifecycleRecovery = nil
        restore()
        if !device.needsRecovery { controlWanted = !demo && device.available; tick(); announceLightReadiness() }
    }
    func setControl(_ wanted: Bool) {
        if !wanted {
            ambientResumeAllowed = false
            invalidateLightReadyNotice()
            // Withdrawal is allowed even inside a verification-pumped callback.
            // Cleanup waits for the active batch, but a restart cannot win.
            savedLidRecoveryAllowed = false; controlWanted = false
            controlOffPending = true
            pendingLifecycleRecovery = nil; reconnecting = false
            if hardwareOperationInProgress || lidCleanupInProgress { requestFrame(); return }
        }
        guard !hardwareOperationInProgress, !lidCleanupInProgress else { notice = "Light recovery is still in progress."; return }
        if demo && hardwareApply == nil { notice = "This is an isolated preview. Your real logo is unchanged."; return }
        controlWanted = wanted
        controlOffPending = false
        savedLidRecoveryAllowed = wanted
        if !wanted { pendingLifecycleRecovery = nil; reconnecting = false; stopLid(); releaseHardware() }
        tick()
    }
    /// Terminal verification pumps the run loop for safety notifications. Keep
    /// timer/user callbacks from entering another hardware operation meanwhile.
    /// Routine applies do not stop capture or schedule another frame.
    @discardableResult func withHardwareApply(_ operation: () throws -> Void) rethrows -> Bool {
        guard !hardwareOperationInProgress else { return false }
        hardwareApplyInProgress = true
        defer { hardwareApplyInProgress = false }
        try operation()
        return true
    }
    @discardableResult func withHardwareRecovery(_ operation: () throws -> Void) rethrows -> Bool {
        guard !hardwareOperationInProgress else { return false }
        hardwareRecoveryInProgress = true
        invalidateLightReadyNotice()
        lastHardwareResult = nil
        musicHardwareReady = false
        if audioRunning || audioStarting { stopAudio() }
        defer { hardwareRecoveryInProgress = false; requestFrame() }
        try operation()
        return true
    }
    func releaseHardware() {
        guard controlling, !hardwareOperationInProgress, !lidCleanupInProgress else { return }
        // A failed sleep/lock cleanup keeps the owned session and journal. Do
        // not repeatedly touch hardware while macOS is still transitioning.
        if automaticRecoveryPending && !isStopping && controlWanted { return }
        do { try restoreOwnedHardware(); pendingLifecycleRecovery = nil }
        catch {
            if !isStopping && controlWanted && lifecycleInterrupted {
                deferLifecycleRecovery(error)
            } else {
                pendingLifecycleRecovery = nil
                lidIntentController.block(); self.error = error.localizedDescription; controlWanted = false
            }
        }
    }
    private func deferLifecycleRecovery(_ failure: Error) {
        guard pendingLifecycleRecovery == nil else { return }
        guard lidIntentController.block(reason: .interruptedCleanup) else {
            hardwareFailure = "The closed-lid recovery choice could not be saved. Restore your light before retrying."
            controlWanted = false; return
        }
        let attempts = lidIntentController.intent?.pause?.attempts ?? 0
        pendingLifecycleRecovery = .init(attempts: attempts, retryAt: recoveryClock() + 0.5, message: failure.localizedDescription)
        reconnecting = true
        recoveryLogger.notice("Owned light cleanup was interrupted; waiting for a safe awake session before retrying.")
        // Keep mode, power and closed-lid intent. No effects resume until the
        // same owned session's restoration has been positively verified.
        notice = "Backlit will reconnect when your Mac is awake and unlocked."
        if error == failure.localizedDescription { error = nil }
        lastHardwareResult = nil; musicHardwareReady = false
        if audioRunning || audioStarting { stopAudio() }
    }
    private func resumeAfterLifecycleRecovery() -> Bool {
        guard var pending = pendingLifecycleRecovery else { return true }
        guard controlWanted, !isStopping, !lifecycleInterrupted, !hardwareOperationInProgress,
              !lidCleanupInProgress, !lidStopPending, !lidStopFailed, pausedReason == nil else { return false }
        let now = recoveryClock()
        guard now.isFinite, now >= pending.retryAt else { return false }
        guard pending.attempts < LidSavedPause.attemptLimit else {
            pendingLifecycleRecovery = nil; reconnecting = false
            lidIntentController.block(); controlWanted = false
            return false
        }
        pending.attempts += 1
        do { try lidIntentController.recordCleanupAttempt(clock: currentLidIntentEnvironment().clock()) }
        catch {
            pendingLifecycleRecovery = nil; reconnecting = false
            hardwareFailure = error.localizedDescription; controlWanted = false
            return false
        }
        recoveryLogger.notice("Retrying verified light cleanup, attempt \(pending.attempts).")
        pendingLifecycleRecovery = pending
        do {
            try restoreOwnedHardware()
            // A successful existing restore callback is not qualified native
            // handback. Preserve any saved pause, its timer and retry history.
            pendingLifecycleRecovery = nil
            reconnecting = false
            if lidIntentController.intent?.savedPause?.needsQualifiedHandback == true {
                recoveryLogger.notice("Cleanup returned, but saved closed-lid handback remains unconfirmed.")
            } else {
                recoveryLogger.notice("Owned cleanup verified; reconnecting the requested light behavior.")
            }
            if error == pending.message { error = nil }
            notice = lidIntentController.intent?.savedPause?.needsQualifiedHandback == true ? LidSavedPause.unconfirmedStatus : nil
            // Restoration can pump Off, brightness, mode or lifecycle changes.
            // The queued next frame recomputes all policy/output; never apply
            // the value calculated before the restore callback returned.
            return false
        } catch {
            guard controlWanted, !isStopping else {
                pendingLifecycleRecovery = nil; reconnecting = false
                return false
            }
            if pending.attempts < 3 {
                pending.retryAt = now + pow(2, Double(pending.attempts - 1))
                pendingLifecycleRecovery = pending
            } else {
                pendingLifecycleRecovery = nil
                reconnecting = false
                recoveryLogger.error("Automatic cleanup retry limit reached; keeping recovery and stopping light control.")
                hardwareFailure = error.localizedDescription; self.error = error.localizedDescription
                lidIntentController.block(); controlWanted = false
            }
            return false
        }
    }
    private func restoreOwnedHardware() throws {
        let restored = try withHardwareRecovery {
            if let hardwareRestore { try hardwareRestore() }
            else { try device.restore() }
            controlling = false
        }
        guard restored else { throw RuntimeServices.failure("Light recovery is still in progress.") }
    }
    func restore() {
        guard !demo, !hardwareOperationInProgress else { return }
        pendingLifecycleRecovery = nil
        savedLidRecoveryAllowed = false
        reconnecting = false
        controlWanted = false
        musicHardwareReady = false
        if audioRunning || audioStarting { stopAudio() }
        if lidStopPending || watcher?.isRunning == true {
            stopLid(); notice = "Closed-lid cleanup is in progress. Retry Restore Light when it finishes."; return
        }
        do {
            try withHardwareRecovery {
                try device.restore(); controlling = false
                let forcePowerRestore = watcher != nil
                guard try finishPowerRecovery({ try RuntimeServices.repairLid(forcePowerRestore: forcePowerRestore) }) else { return }
                if lidIntentController.intent?.savedPause?.needsQualifiedHandback == true {
                    notice = "Restoration was requested. Native handback remains unconfirmed, so the saved closed-lid choice stays paused."
                    return
                } else if lidIntentController.intent?.blocked == true {
                    lidIntentController.block(detail: "Your light was restored. Turn closed-lid lighting off and on to retry.")
                }
                notice = "The saved logo and lid settings were restored."
            }
        }
        catch { self.error = error.localizedDescription }
    }
    /// Owned journals exist during healthy operation too. Readiness therefore
    /// requires an applied frame, not a waiting helper or a safely paused fade.
    /// A frame that has issued its command and is waiting to observe the
    /// output is still owned, healthy hardware. In Music that happens on
    /// every beat that crosses zero. Treating each such frame as "not ready"
    /// stopped capture, which silenced the audio, which made the next frame
    /// ready again: capture restarted about twice a second. Readiness earned
    /// by an applied frame is therefore kept across brief waits. A wait that
    /// persists, a pause, an error or a recovery still withdraws it.
    static let musicReadinessGrace = 2.0
    private var lastMusicReadyFrame: Double?
    func updateMusicHardwareReadiness(_ operation: () throws -> FadeApplyResult) rethrows {
        let wasReady = musicHardwareReady
        musicHardwareReady = false
        lastHardwareResult = nil
        defer { if lastHardwareResult != .applied { invalidateLightReadyNotice() } }
        let result = try operation()
        lastHardwareResult = result
        let now = recoveryClock()
        switch result {
        case .applied:
            musicHardwareReady = true; lastMusicReadyFrame = now
        case .waiting:
            if wasReady, let last = lastMusicReadyFrame, now.isFinite, now >= last,
               now - last <= Self.musicReadinessGrace { musicHardwareReady = true }
            else { lastMusicReadyFrame = nil }
        case .paused:
            lastMusicReadyFrame = nil
        }
    }
    var musicCaptureAllowed: Bool {
        let observed = musicCaptureObservation?() ?? .init(deviceAvailable: device.available,
                                                         locked: cachedLocked, lidClosed: cachedLid)
        let allowedClosed = keepClosed && observed.lidClosed
        return lifecycleAllowsFrames && controlWanted && controlling &&
            musicHardwareReady && observed.deviceAvailable && !observed.locked &&
            mode == .music && enabled && pausedReason == nil && !systemSleeping && consoleActive &&
            (!screenSleeping || allowedClosed)
    }
    private func synchronizeMusicCapture() {
        switch MusicCapturePolicy.action(mode: mode, enabled: enabled, eligible: musicCaptureAllowed,
            preview: demo, failed: audioPermissionHelp, active: audioRunning || audioStarting) {
        case .start: startAudio()
        case .stop: stopAudio()
        case .none: break
        }
    }
    private func clearAudioFailure() {
        if let audioCaptureError, error == audioCaptureError { error = nil }
        audioCaptureError = nil; audioPermissionHelp = false
    }
    func startAudio() {
        if demo { notice = "Preview uses a sample waveform. Live system audio is never started in preview."; return }
        guard musicCaptureAllowed, !audioStarting, !audioRunning, !audioStopping else { return }
        clearAudioFailure()
        audioSession.requestStart()
    }
    func openAudioPrivacy() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func stopAudio() {
        musicResponse.reset()
        audioSession.requestStop()
        audioRunning = false; audioStarting = false
        requestFrame()
    }
    private func resumeAudioAfterInterruption() {
        guard audioSession.hasResumeIntent else { return }
        // Refresh sleep/lock/session policy before considering the saved intent.
        lastSourceSample = -Double.infinity
        tick()
        audioSession.resumeAfterInterruption(consented: audioConsent)
    }
    func setLidDuration(mode: LidDurationMode? = nil, amount: Int? = nil, unit: LidDurationUnit? = nil) {
        guard canEditLidDuration else { return }
        lidSessionDuration = LidSessionDuration(mode: mode ?? lidSessionDuration.mode,
            amount: amount ?? lidSessionDuration.amount, unit: unit ?? lidSessionDuration.unit)
    }
    func setLid(_ enabled: Bool) {
        // Off withdraws future resume intent even if a hardware operation is
        // currently pumping callbacks. Cleanup begins once that batch returns.
        if !enabled {
            savedLidRecoveryAllowed = false
            lidIntentController.disable(); lidRequested = false; lidPreferenceStatus = "Off"
            lidOffPending = true
            stopLid(); requestFrame(); return
        }
        guard !hardwareOperationInProgress, !lidCleanupInProgress else { notice = "Light recovery is still in progress."; return }
        guard !demo || hardwareApply != nil else { notice = "Closed-lid operation is unavailable in isolated preview."; return }
        guard watcher == nil, !lidStopPending, !lidStopper.hasOutstandingFilesystemWork else {
            error = "Finish the previous closed-lid session cleanup before starting another."; return
        }
        do {
            savedLidRecoveryAllowed = true
            try lidIntentController.enable(duration: lidSessionDuration, environment: currentLidIntentEnvironment())
            lidRequested = true
            synchronizeLidIntent(force: true)
        } catch {
            lidRequested = lidIntentController.intent != nil; self.error = error.localizedDescription
            lidPreferenceStatus = "Paused after an error. Restore your light before retrying."
        }
    }
    private func recoverSavedLidPause() {
        // No production handback provider has been qualified. Journal absence
        // and stable native caches cannot rule out retained synthetic overrides
        // or late requests. Keep the choice/budget untouched, without probing.
        // Only isolated fixtures exercise the future bounded admission logic.
        guard let supplied = lidPauseRecoveryEnvironment,
              supplied.available(inPreview: demo) else { return }
        guard savedLidRecoveryAllowed, !savedLidCheckInProgress, enabled, !isStopping,
              !controlling, watcher == nil, !automaticRecoveryPending,
              !hardwareOperationInProgress, !lidCleanupInProgress, !lidStopPending,
              !lidStopFailed, !lidStopper.hasOutstandingFilesystemWork,
              lidIntentController.intent?.savedPause?.canRetry == true else { return }
        savedLidCheckInProgress = true
        defer { savedLidCheckInProgress = false }
        let environment = LidPauseRecoveryEnvironment(clock: supplied.clock, eligible: { [weak self] in
            guard let self, self.savedLidRecoveryAllowed, self.enabled, !self.isStopping,
                  !self.systemSleeping, self.consoleActive else { return false }
            return supplied.eligible()
        }, verify: supplied.verify, allowsAutomaticClearance: true)
        guard let clock = environment.clock(),
              let pause = lidIntentController.intent?.savedPause,
              pause.hasImpossibleBackoff(clock: clock) ||
                (pause.ready(clock: clock) && environment.eligible()) else { return }
        do {
            try withHardwareRecovery {
                if try lidIntentController.recoverSavedPause(environment: environment) {
                    controlWanted = true
                    lidPreferenceStatus = "Previous session verified. Reconnecting your remembered choice."
                }
            }
        } catch {
            lidIntentController.block(detail: "The saved safety check could not be recorded. Restore your light before retrying.")
            self.error = error.localizedDescription
        }
    }
    private func currentLidIntentEnvironment() -> LidIntentEnvironment {
        if let lidIntentEnvironment { return lidIntentEnvironment }
        return LidIntentEnvironment(clock: { LidContinuousClock.live() }, closed: { RuntimeServices.physicalLidClosed }, safety: { [weak self] in
            let power = RuntimeServices.batterySnapshot()
            let closed = RuntimeServices.physicalLidClosed
            return LidResumeSafety(preview: self?.demo != false, enabled: self?.enabled == true,
                owned: self?.controlWanted == true && self?.controlling == true && self?.device.available == true &&
                    (self?.watcher != nil || self?.lastHardwareResult == .applied || self?.lastHardwareResult == .paused),
                cleanupClear: self?.hardwareOperationInProgress == false && self?.lidCleanupInProgress == false &&
                    self?.lidStopPending == false && self?.lidStopFailed == false &&
                    (self?.watcher != nil || !LidWatcherStopper.journalNeedsRecovery(AgentBridge.directory.appendingPathComponent("lid-recovery.json"))),
                awake: self?.systemSleeping == false && self?.consoleActive == true && (closed == true || self?.screenSleeping == false),
                unlocked: LidResumeSafety.sessionUnlocked(), externalPower: power?.externalPower == true,
                battery: power?.level, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState)
        }, checkpoints: .init(directory: AgentBridge.directory), start: { intent, lease in
            try FileManager.default.createDirectory(at: lease.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: lease, options: .atomic)
            let process = Process(); process.executableURL = Bundle.main.executableURL
            process.arguments = ["--watch-lid", String(getpid()), lease.path, String(intent.durationSeconds), intent.id.uuidString]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run(); return process }
            catch { try? FileManager.default.removeItem(at: lease); throw error }
        })
    }
    func synchronizeLidIntent(force: Bool = false, preflightOnly: Bool = false) {
        guard !hardwareOperationInProgress else { return }
        let intent = lidIntentController.intent
        if lidRequested && intent == nil { lidOffPending = true }
        lidRequested = intent != nil
        if intent == nil {
            lidPreferenceStatus = "Off"
            if lidOffPending { stopLid() }
            return
        }
        guard !demo || hardwareApply != nil else { lidPreferenceStatus = "Remembered. Preview never starts a closed-lid session."; return }
        guard !isStopping, !lidCleanupInProgress, !lidStopPending else { return }
        let environment = currentLidIntentEnvironment()
        let now = environment.clock()?.seconds ?? ProcessInfo.processInfo.systemUptime
        guard force || now < lastLidIntentCheck || now - lastLidIntentCheck >= 1 else { return }
        if let intent, watcher != nil {
            lastLidIntentCheck = now
            guard !intent.blocked else { lidPreferenceStatus = "Paused after an error. Turn “Keep logo on with lid closed” off and on after recovery."; stopLid(); return }
            guard environment.safety().eligible else {
                lidPreferenceStatus = "Remembered. Paused for your Mac’s safety settings."
                stopLid(); return
            }
            let closed = environment.closed()
            let checkpoint = environment.checkpoints.read(intent.id), clock = environment.clock()
            switch LidIntentPolicy.timer(intent: intent, checkpoint: checkpoint, clock: clock, closed: closed) {
            case .expired:
                lidPreferenceStatus = "Timer finished. Reopen the lid to begin another timed session."; stopLid()
            case .needsOpen:
                lidPreferenceStatus = "Remembered. Open the lid before starting another timed session."
                // An active helper may be between its observed open and first
                // closed poll. It must write the deadline before granting light.
                if !(clock.map { checkpoint?.valid(for: intent, clock: $0) == true && checkpoint?.closedAt == nil } ?? false) { stopLid() }
            case .unavailable:
                lidPreferenceStatus = "Remembered. Waiting for a verified lid and timer state."; stopLid()
            case .ready:
                lidPreferenceStatus = closed == false ? "Ready for the next lid closure." :
                    (ClosedEffectSession.permitted() ? "Active. Safety limits still apply." : "Waiting for closed-lid safety checks.")
            }
            return
        }
        guard !preflightOnly else { return }
        lastLidIntentCheck = now
        do {
            switch try lidIntentController.resume(environment: environment) {
            case .off: lidRequested = lidIntentController.intent != nil; lidPreferenceStatus = "Off"
            case let .paused(message): lidPreferenceStatus = message
            case let .started(started, process, lease):
                guard adoptLidWatcher(process, lease: lease) else { throw RuntimeServices.failure("The closed-lid helper could not be adopted.") }
                if lidIntentController.intent?.id != started.id { stopLid() }
                else { lidPreferenceStatus = "Starting closed-lid safety checks…" }
            }
        } catch { lidIntentController.block(); self.error = error.localizedDescription; lidPreferenceStatus = "Paused after an error. Restore your light before retrying." }
    }
    func setPreviewLidSleep(_ sleeping: Bool) {
        guard demo else { return }
        screenSleeping = sleeping
    }
    /// Retain one owned helper until its exit and recovery record are checked.
    @discardableResult func adoptLidWatcher(_ process: any LidWatcherProcess, lease: URL) -> Bool {
        guard !hardwareOperationInProgress, watcher == nil, !lidStopPending, !lidStopper.hasOutstandingFilesystemWork else { return false }
        watcher = process; self.lease = lease; keepClosed = true; lidStopFailed = false
        return true
    }
    func stopLid() {
        guard !hardwareOperationInProgress else { return }
        lidOffPending = false
        keepClosed = false
        guard let watcher, !lidStopPending else { return }
        // Stop producing frames before revoking the helper's permission. The
        // fade watchdog and this process must not race ordinary animation.
        lidCleanupInProgress = true
        if lidRequested { lidPreferenceStatus = "Cleaning up. Your choice is remembered." }
        musicHardwareReady = false
        synchronizeTouch(); synchronizeTyping(); stopAudio(); timer?.invalidate()
        if lidStopper.requestStop(process: watcher, lease: lease,
            journal: AgentBridge.directory.appendingPathComponent("lid-recovery.json")) {
            lidStopPending = true; lidStopFailed = false
        } else {
            lidCleanupInProgress = false
            synchronizeTouch(); synchronizeTyping(); configureTimer(); requestFrame()
        }
    }
    /// Only an explicit successful power repair can retire a failed helper.
    /// The caller must successfully restore the power override, not merely delete a file.
    @discardableResult func completePowerRecovery(_ repair: () throws -> Void) rethrows -> Bool {
        guard !hardwareOperationInProgress else { return false }
        return try finishPowerRecovery(repair)
    }
    private func finishPowerRecovery(_ repair: () throws -> Void) rethrows -> Bool {
        guard !lidStopPending, !lidStopper.hasOutstandingFilesystemWork, watcher?.isRunning != true else { return false }
        try repair()
        watcher = nil; lease = nil; lidStopFailed = false
        return true
    }
    func setAmbient(_ enabled: Bool) {
        guard !ambientChangeInProgress, !hardwareOperationInProgress, !savedLidCheckInProgress, !isStopping else {
            notice = "Light recovery is still in progress."; return
        }
        // Fixtures must replace both hardware operations as well as authorization.
        let isolated = demo && ambientAuthorization != nil && hardwareRestore != nil && hardwareApply != nil
        guard isolated || (!demo && device.available) else { error = "A compatible live Mac is required."; return }
        if !isolated, let app = device.competingApp { error = "Quit \(app) before changing logo settings."; return }
        guard watcher == nil, !lidStopPending, !lidCleanupInProgress, !lidStopFailed,
              !lidStopper.hasOutstandingFilesystemWork else {
            notice = "Turn off closed-lid lighting and finish its cleanup before changing ambient limits."; return
        }
        let resume = controlWanted
        ambientChangeInProgress = true; ambientResumeAllowed = true
        defer { ambientChangeInProgress = false; ambientAuthorizationInProgress = false; requestFrame() }
        controlWanted = false
        releaseHardware()
        guard ambientCleanupSafe(isolated: isolated), ambientResumeAllowed else {
            if error == nil { error = "Restore your light before changing ambient limits." }
            return
        }
        // The authorization dialog pumps the run loop. Block frames, duplicate
        // prompts and recovery while it is open, but retain new Off/Quit intent.
        ambientAuthorizationInProgress = true
        var mayResume = false
        do {
            try (ambientAuthorization ?? RuntimeServices.authorizedAmbient)(enabled)
            ambientUnlocked = enabled; defaults.set(enabled,forKey:"ambientUnlocked")
            mayResume = true
        } catch AmbientAuthorizationFailure.cancelled {
            notice = "Ambient brightness limits were not changed."
            mayResume = true
        } catch {
            // A helper failure may follow a partial privileged write. Unlike
            // cancellation, it is not evidence that the old state is intact.
            self.error = error.localizedDescription
        }
        // Discard any ownership request made by a callback inside the dialog.
        // Only the captured intent and the cancellation/cleanup gates may resume.
        controlWanted = false
        ambientAuthorizationInProgress = false
        if mayResume && resume && ambientResumeAllowed && ambientCleanupSafe(isolated: isolated) {
            setControl(true)
        }
    }
    private func ambientCleanupSafe(isolated: Bool) -> Bool {
        !controlling && !hardwareRecoveryInProgress && !hardwareApplyInProgress &&
            !lidCleanupInProgress && !lidStopPending && !lidStopFailed && watcher == nil &&
            !lidStopper.hasOutstandingFilesystemWork && !automaticRecoveryPending &&
            !isStopping && !controlOffPending && hardwareFailure == nil &&
            lidIntentController.intent?.blocked != true && (isolated || !device.needsRecovery)
    }
    var loginEnabled: Bool { !demo && SMAppService.mainApp.status == .enabled }
    func setLogin(_ value: Bool) {
        guard !demo else { return }
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }
    func connectAgent(_ agent: CodingAgent, _ enabled: Bool) {
        guard !demo else { notice = "Connections are disabled in isolated preview."; return }
        do { try AgentBridge.connect(agent,enabled:enabled); notice = enabled ? (agent == .codex ? "Hooks installed. Review and trust them in Codex Settings → Hooks, then start a new session." : "Hooks installed. Start a new Claude Code session to see status.") : "Backlit's hooks were removed. Existing hooks were preserved."; objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }
    func chooseFolder(_ agent: CodingAgent) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let folder = panel.url { defaults.set(folder.path,forKey:"agent.folder."+agent.rawValue); objectWillChange.send() }
    }
    func configureBridge(enabled: Bool, lan: Bool) {
        guard !demo else { notice = "Network sharing is disabled in isolated preview."; return }
        bridge.stop(); bridgeEnabled = false; bridgeLAN = lan
        do {
            if enabled { try bridge.start(lan:lan,token:BridgeToken.value()); bridgeEnabled = true }
            else { bridgeStatus = "Not connected" }
            defaults.set(enabled,forKey:"bridge.enabled"); defaults.set(lan,forKey:"bridge.lan")
        } catch { self.error = error.localizedDescription }
    }
    func copyToggleLink() {
        guard !demo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("backlit://toggle", forType: .string)
        notice = "Backlit link copied. Use it with a launcher that supports custom app links."
    }
    func copyPairingKey() {
        guard !demo else { return }
        do { let token = try BridgeToken.value(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token,forType:.string); notice = "Pairing key copied. Paste it into Home Assistant; keep it private." }
        catch { self.error = error.localizedDescription }
    }
    /// The key travels over plain HTTP on the local network, so there must be
    /// a way to replace one that may have been seen. Explicit user action only.
    func regeneratePairingKey(confirm: (() -> Bool)? = nil) {
        guard !demo else { return }
        let approved: Bool
        if let confirm { approved = confirm() }
        else {
            let alert = NSAlert(); alert.messageText = "Create a new pairing key?"
            alert.informativeText = "The current key stops working immediately. Home Assistant will ask for the new key before it can control the light again."
            alert.addButton(withTitle:"Create New Key"); alert.addButton(withTitle:"Cancel")
            approved = alert.runModal() == .alertFirstButtonReturn
        }
        guard approved else { return }
        let lan = bridgeLAN
        switch PairingKeyRotation.run(wasSharing: bridgeEnabled, stopSharing: {
            // From here the old key is refused, whatever happens next.
            bridge.stop(); bridgeEnabled = false; bridgeStatus = "Not connected"
        }, regenerate: { try BridgeToken.regenerate() }) {
        case .rotated(let restartSharing):
            if restartSharing { configureBridge(enabled: true, lan: lan) }
            notice = "A new pairing key was created. Copy it and update Home Assistant; the old key no longer works."
        case .failed(let reason):
            // Also remember Off, so a relaunch cannot bring the old key back.
            configureBridge(enabled: false, lan: lan)
            self.error = "A new pairing key could not be created, so Home Assistant sharing was switched off. Choose New Pairing Key again before switching it back on. (\(reason))"
        }
    }
    func apiState() -> [String:Any] {
        ["id":id,"name":"Backlit","version":Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development","build":Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0","enabled":enabled,"brightness":Int(((mode == .battery ? output : Effects.clamp(brightness))*255).rounded()),
         "effect":mode.title,"effects":availableModes.map(\.title),"battery":Effects.percent(battery),
         "charging":charging,"actively_charging":activelyCharging,"agent_state":agents.isEmpty ? "no_recent_signals" : agentState.rawValue,
         "agent_sessions":agents.count,"hardware_supported":device.available,"controlling":controlling,
         "preview":!controlling,"paused":pausedReason ?? "","output":output,
         "battery_available":batteryAvailable,"charge_ready":chargeReady,"automation_enabled":automationsEnabled]
    }
    func resumeAfterUpdateFailure() {
        guard isStopping && terminationApproved else { return }
        isStopping = false; terminationApproved = false
        controlWanted = !demo && device.available && !device.needsRecovery
        startPowerMonitoring()
        if bridgeEnabled { configureBridge(enabled: true, lan: bridgeLAN) }
        configureTimer(); requestFrame()
        resumeAudioAfterInterruption()
    }
    func quit() {
        guard updater.allowsTermination() else { error = updater.message; return }
        quitRunLoop.request { NSApp.terminate(nil) }
    }
    func prepareQuit(reason: QuitReason = .userInitiated, confirmOff: (() -> NSApplication.ModalResponse)? = nil) -> Bool {
        ambientResumeAllowed = false
        guard !hardwareOperationInProgress, !savedLidCheckInProgress else {
            // Withdraw automatic rearm, but do not schedule restoration here:
            // an Off logo may require the existing Restore-and-Quit consent.
            savedLidRecoveryAllowed = false; controlWanted = false
            pendingLifecycleRecovery = nil; reconnecting = false
            notice = "Light recovery is still in progress. Retry Quit when it finishes."
            return false
        }
        if terminationApproved { return true }
        if !isStopping {
            audioSession.retainResumeIntent(consented: audioConsent)
            isStopping = true
            synchronizeTouch(); synchronizeTyping(); powerMonitor.stop(); timer?.invalidate(); stopAudio()
            if controlling && !enabled && reason.requiresOffConfirmation {
                let result: NSApplication.ModalResponse
                if let confirmOff { result = confirmOff() }
                else {
                    let alert = NSAlert(); alert.messageText = "Restore the logo and quit?"; alert.informativeText = "Quitting restores the native logo settings saved before this Backlit session. The logo may turn on again."
                    alert.addButton(withTitle:"Restore and Quit"); alert.addButton(withTitle:"Cancel")
                    result = alert.runModal()
                }
                guard result == .alertFirstButtonReturn else { cancelStopping(); return false }
            }
        }
        // Cocoa's terminateLater path keeps the run loop responsive while the
        // owned helper restores power. No hardware/quit decision is discarded.
        if watcher != nil || lidStopPending {
            stopLid()
            if !lidStopPending { cancelStopping() }
            return false
        }
        stopLid(); releaseHardware()
        if controlling { cancelStopping(); return false }
        timer?.invalidate(); bridge.stop(); stopAudio(); terminationApproved = true; return true
    }
    private func cancelStopping() {
        guard isStopping else { return }
        isStopping = false
        startPowerMonitoring(); synchronizeTouch(forceRestart: true); synchronizeTyping(forceRestart: true)
        configureTimer(); requestFrame()
        resumeAudioAfterInterruption()
    }
}
