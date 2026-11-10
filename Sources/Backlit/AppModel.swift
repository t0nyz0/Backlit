import AppKit
import SwiftUI
import ServiceManagement
import Combine

@MainActor final class LightPresentation: ObservableObject {
    @Published var level = 0.0
}

@MainActor final class AppModel: ObservableObject {
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
    private var typingWanted = false
    private var touchWanted = false
    @Published var typingStatus = "Typing response is off"
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
    @Published var signalStatus = "No active signals"
    @Published var signalCount = 0
    @Published var focusMinutes = 25
    @Published var automationsEnabled = false {
        didSet {
            guard !isLoading else { return }
            defaults.set(automationsEnabled, forKey: "automation.enabled")
            AutomationRouter.shared.enabled = automationsEnabled && !demo
            if !automationsEnabled { signals.clearExternal(); requestFrame() }
        }
    }
    private var batteryResponse = BatteryResponse()
    private var musicResponse = MusicResponse()
    private var signals = ActivitySignalEngine()
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
    @Published var mode: GlowMode = .battery { didSet { guard !isLoading else{return}; lastSourceSample = -Double.infinity; if mode == .battery {lastBatterySample = -Double.infinity}; save(); if mode != .music { stopAudio() } else if audioConsent { startAudio() }
        synchronizeTouch()
        batteryResponse.reset(); musicResponse.reset(); synchronizeTyping(); configureTimer(); requestFrame() } }
    @Published var enabled = true { didSet {
        guard !isLoading else{return}
        defaults.set(enabled,forKey:"enabled")
        if !demo && device.available && !device.needsRecovery { controlWanted = true }
        synchronizeTouch()
        if !enabled && (audioRunning || audioStarting) {stopAudio()}
        else if enabled && mode == .music && audioConsent {startAudio()}
        synchronizeTyping(); requestFrame(); configureTimer()
    } }
    @Published var brightness = 0.68 { didSet { save(); requestFrame() } }
    @Published var period = 6.0 { didSet { save(); requestFrame() } }
    @Published var intensity = 1.0 { didSet { save(); requestFrame() } }
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
    @Published var audioStarting = false
    @Published var keepClosed = false
    @Published var ambientUnlocked = false
    @Published var bridgeEnabled = false
    @Published var bridgeLAN = false
    @Published var bridgeStatus = "Not connected"
    @Published var language = "en" { didSet { save() } }
    @Published var appearance = "system" { didSet { save() } }
    @Published var error: String?
    @Published var notice: String?
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
    private var isStopping = false
    private var tickCount = 0
    private var lastSourceSample = -Double.infinity
    private var lastBatterySample = -Double.infinity
    private var lastPreviewSample = -Double.infinity
    private var timerInterval = 0.0
    private var framePending = false
    private var competingController: String?
    private var cachedLid = false
    private var cachedLocked = false
    private var cachedAway = false
    private var audioConsent = false
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
            if state == .running { self.audioConsent = true }
            self.requestFrame()
        },
        failed: { [weak self] error in
            guard let self else { return }
            self.audioPermissionHelp = true
            self.error = SystemAudio.friendly(error).localizedDescription
            self.requestFrame()
        })
    private var screenSleeping = false
    private var systemSleeping = false
    private var consoleActive = true
    private var watcher: (any LidWatcherProcess)?
    private let lidStopper: LidWatcherStopper
    private(set) var lidStopPending = false
    var onLidStopCompleted: ((Bool) -> Void)?
    private var lidStopFailed = false
    private var lease: URL?
    private var observers: [NSObjectProtocol] = []
    private let epoch = ProcessInfo.processInfo.systemUptime
    var id: String { defaults.string(forKey:"installation.id")! }
    var agentState: AgentState { AgentBridge.aggregate(agents) }
    var isChinese: Bool { language == "zh-Hant" }
    func t(_ english: String, _ chinese: String) -> String { isChinese ? chinese : english }
    var status: String {
        if let pausedReason { return pausedReason }
        if demo { return t("Preview · logo unchanged","預覽・不會更改標誌") }
        if !device.available { return t("Preview · compatible logo not found","預覽・未找到相容標誌") }
        if !controlWanted && device.needsRecovery { return "Restore your light to continue" }
        if !enabled { return t("Logo off","標誌已關閉") }
        guard controlling else { return "Connecting to your MacBook" }
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
        case .signals:return signalStatus
        case .touch:return touchDown || typingDown ? "Input active · light on" : typingEnabled ? "Ready for trackpad or typing" : "Ready for \(touchSource.title.lowercased()) touch"
        }
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    init(demo: Bool = false, defaults: UserDefaults? = nil, lidStopper: LidWatcherStopper? = nil) {
        self.lidStopper = lidStopper ?? LidWatcherStopper()
        self.demo = demo
        self.defaults = defaults ?? (demo ? UserDefaults(suiteName:(Bundle.main.bundleIdentifier ?? "local.backlit") + ".preview")! : .standard)
        if let visible = self.defaults.object(forKey: "menuBarIcon.visible") as? Bool { menuBarIconVisible = visible }
        device = LogoDevice(directory:AgentBridge.directory)
        if let raw = self.defaults.string(forKey:"mode"), let mode = GlowMode(rawValue:raw) { self.mode = mode }
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
                self.typingWanted = false
                return
            }
            self.typingDown = active
            self.requestFrame()
        }
        typing.onStatus = { [weak self] status in self?.typingStatus = status }
        bridge.signal = { [weak self] signal in
            guard let self else { return }
            try self.performAutomation(.signal(signal))
        }
        audio.onFailure = { [weak self] text, token in Task { @MainActor in
            guard let self, self.audioRunning, self.audio.acceptsFailure(token) else { return }
            self.audioSession.requestStop()
            self.audioRunning = false; self.error = text; self.requestFrame()
        } }
        bridge.state = { [weak self] in self?.apiState() ?? [:] }
        bridge.command = { [weak self] command in
            guard let self else { return }
            guard self.controlling, self.pausedReason == nil else { throw RuntimeServices.failure("Open Backlit on the Mac and restore its light if a recovery message is shown.") }
            if command.mode == .music && !self.audioConsent { throw RuntimeServices.failure("Start System Audio in Backlit before selecting Music remotely.") }
            if let mode = command.mode { guard self.availableModes.contains(mode) else { throw RuntimeServices.failure("That mode is unavailable on this Mac.") }; self.mode = mode }
            if let brightness = command.brightness { self.brightness = brightness }
            if let enabled = command.enabled { self.enabled = enabled }
            self.tick()
        }
        bridge.onStatus = { [weak self] text in self?.bridgeStatus = text }
        self.lidStopper.onResult = { [weak self] result in
            guard let self else { return }
            self.lidStopPending = false
            self.lidStopFailed = !result.safeToQuit
            if result.safeToQuit {
                self.watcher = nil; self.lease = nil
                if result.leaseRemovalError != nil { self.notice = "Normal lid sleep was restored. A leftover session file could not be removed." }
            } else {
                self.error = "Closed-lid cleanup could not be confirmed. Review power recovery in Settings, then retry."
            }
            self.onLidStopCompleted?(result.safeToQuit)
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
        for (name,action) in states { observers.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task { @MainActor in if let self { action(self); self.synchronizeTouch(); self.synchronizeTyping(); self.requestFrame() } }}) }
        controlWanted = !demo && device.available && !device.needsRecovery
        configureTimer()
        if !demo && !controlWanted && device.needsRecovery { notice = "A previous logo session needs restoration. Use Restore Light to pick up where you left off." }
        if !demo && self.defaults.bool(forKey:"bridge.enabled") { configureBridge(enabled:true,lan:self.defaults.bool(forKey:"bridge.lan")) }
        startPowerMonitoring()
        // The first tick samples lock/power/ownership policy before either
        // input monitor can register. All starts go through synchronization.
        tick()
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
        guard !isStopping else { return }
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
            if mode == .agents || bridgeEnabled {
                let nextAgents=demo ? [] : AgentBridge.events().sorted{$0.time<$1.time}
                if agents != nextAgents {agents=nextAgents}
            }
            cachedLid = demo ? false : RuntimeServices.lidClosed
            cachedLocked = demo ? false : RuntimeServices.locked
            cachedAway = demo ? false : RuntimeServices.away
        }
        let allowClosed = keepClosed && cachedLid
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        var nextPause: String?
        if systemSleeping { nextPause = "Mac is sleeping" }
        else if let competingController { nextPause = "Quit \(competingController) to use Backlit" }
        else if !consoleActive { nextPause = "User session inactive" }
        else if ProcessInfo.processInfo.thermalState == .critical { nextPause = "Paused while your Mac cools down" }
        else if !demo && mode != .agents && !allowClosed && (screenSleeping || cachedLocked) { nextPause = "Paused with your display" }
        else if !demo && lowPower && mode != .agents && mode != .battery { nextPause = "Paused in Low Power Mode" }
        else { nextPause = nil }
        if pausedReason != nextPause {
            pausedReason = nextPause
            if nextPause == nil && enabled && mode == .music && audioConsent { startAudio() }
        }
        synchronizeTouch()
        synchronizeTyping()
        if nextPause != nil && touchDown { touch.reset() }
        let nextOutput = effectOutput(at: now)
        output = nextOutput
        if visualUpdatesAllowed && (isPreviewVisible?() != false) && now-lastPreviewSample >= 0.1 && abs(presentation.level-nextOutput) > 0.005 { presentation.level = nextOutput; lastPreviewSample = now }
        // Capture pauses independently of hardware ownership: losing the
        // device must not keep audio active after display sleep or lock.
        if pausedReason != nil && (audioRunning || audioStarting) { stopAudio() }
        if controlWanted && !demo {
            if pausedReason != nil { releaseHardware() }
            else {
                do {
                    if !controlling { try device.begin(); controlling = true }
                    try device.apply(output)
                } catch { self.error = error.localizedDescription; controlWanted = false; releaseHardware() }
            }
        }
        onIconChange?()
        configureTimer()
        if let watcher, !watcher.isRunning, !lidStopPending, !lidStopFailed { stopLid() }
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
        input.signalLevel = signals.level(at: now)
        let signal = signals.current
        let nextSignalStatus = signal.map { "\($0.category.rawValue.capitalized) · \($0.state.rawValue)" } ?? "No active signals"
        if signalStatus != nextSignalStatus { signalStatus = nextSignalStatus }
        if signalCount != signals.count { signalCount = signals.count }
        input.agent = agentState; input.away = cachedAway
        // A deliberately selected physical light effect must not silently turn
        // into Steady because the owner reduces on-screen interface motion.
        input.touchDown = (touchDown && !touchBlinking) || typingDown
        return pausedReason == nil ? Effects.level(at: now - epoch, input: input) : 0
    }
    func requestFrame() {
        guard !framePending else { return }
        framePending = true
        DispatchQueue.main.async { [weak self] in self?.framePending=false;self?.tick() }
    }
    func configureTimer() {
        let animated = enabled && pausedReason == nil && (mode == .breathe || (mode == .music && (audioRunning || demo)) || (mode == .agents && agentState != .waiting) || (mode == .battery && batteryResponse.requiresAnimation) || (mode == .signals && signals.requiresAnimation))
        let interval = animated ? 0.05 : 1.0
        guard timerInterval != interval || timer?.isValid != true else { return }
        timer?.invalidate(); timerInterval = interval
        let next=Timer(timeInterval:interval,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
        next.tolerance=animated ? 0.003 : 0.1
        RunLoop.main.add(next,forMode:.common);timer=next
    }
    private func synchronizeTouch(forceRestart: Bool = false) {
        let shouldRun = !demo && !isStopping && controlWanted && mode == .touch && enabled && pausedReason == nil && !cachedLocked && !screenSleeping && !systemSleeping && consoleActive
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
    private func synchronizeTyping(forceRestart: Bool = false) {
        let shouldRun = !demo && !isStopping && controlWanted && mode == .touch && enabled && typingEnabled && pausedReason == nil && !cachedLocked && !screenSleeping && !systemSleeping && consoleActive
        if shouldRun && (!typingWanted || forceRestart) { _ = typing.start() }
        else if !shouldRun && typing.running { typing.stop() }
        typingWanted = shouldRun
        if !shouldRun { typingDown = false }
    }
    func setTypingEnabled(_ enabled: Bool) {
        guard !demo else { notice = "Typing input is disabled in preview."; return }
        if enabled && !typing.permissionGranted { _ = typing.requestPermission() }
        let restart = typingEnabled == enabled
        typingEnabled = enabled
        if restart { synchronizeTyping(forceRestart: enabled) }
    }
    func performAutomation(_ command: AutomationCommand) throws {
        guard automationsEnabled, !demo else { throw RuntimeServices.failure("Enable Shortcuts and other apps in Connections first.") }
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
        case .signal(let signal): signals.submit(signal, at: ProcessInfo.processInfo.systemUptime)
        }
        tick()
    }
    func startFocus() {
        let duration = Double(min(120, max(1, focusMinutes))) * 60
        guard let signal = try? ActivitySignal(category: .focus, state: .active, duration: duration, progress: nil) else { return }
        signals.submit(signal, at: ProcessInfo.processInfo.systemUptime, source: .local)
        requestFrame()
    }
    func clearSignals() { signals.reset(); requestFrame() }

    func repairAndResume() {
        restore()
        if !device.needsRecovery { controlWanted = !demo && device.available; notice = "Your light is ready."; tick() }
    }
    func setControl(_ wanted: Bool) {
        if demo { notice = "This is an isolated preview. Your real logo is unchanged."; return }
        controlWanted = wanted
        if !wanted { stopLid(); releaseHardware() }
        tick()
    }
    func releaseHardware() {
        guard controlling else { return }
        do { try device.restore(); controlling = false }
        catch { self.error = error.localizedDescription; controlWanted = false }
    }
    func restore() {
        guard !demo else { return }
        controlWanted = false
        if lidStopPending || watcher?.isRunning == true {
            stopLid(); notice = "Closed-lid cleanup is in progress. Retry Restore Light when it finishes."; return
        }
        do {
            try device.restore(); controlling = false
            let verify = watcher != nil
            guard try completePowerRecovery({ try RuntimeServices.repairLid(verifyNormalSleep: verify) }) else { return }
            notice = "The saved logo and lid settings were restored."
        }
        catch { self.error = error.localizedDescription }
    }
    private var musicCaptureAllowed: Bool {
        let allowedClosed = keepClosed && cachedLid
        return !isStopping && mode == .music && enabled && pausedReason == nil && !systemSleeping && consoleActive && (!screenSleeping || allowedClosed) && (!cachedLocked || allowedClosed)
    }
    func startAudio() {
        guard musicCaptureAllowed, !audioStarting, !audioRunning else { return }
        if demo { notice = "Preview uses a sample waveform. Live system audio is never started in preview."; return }
        audioPermissionHelp = false
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
    private func resumeAudioAfterUpdateFailure() {
        guard audioSession.hasResumeIntent else { return }
        // Refresh sleep/lock/session policy before considering the saved intent.
        lastSourceSample = -Double.infinity
        tick()
        audioSession.resumeAfterInterruption(consented: audioConsent)
    }
    func setLid(_ enabled: Bool) {
        guard !demo else { notice = "Closed-lid operation is unavailable in isolated preview."; return }
        if !enabled { stopLid(); return }
        guard watcher == nil, !lidStopPending, !lidStopper.hasOutstandingFilesystemWork else {
            error = "Finish the previous closed-lid session cleanup before starting another."; return
        }
        guard controlling, device.competingApp == nil else { error = "Your logo needs to be ready before starting a closed-lid session."; return }
        do {
            try FileManager.default.createDirectory(at:AgentBridge.directory,withIntermediateDirectories:true)
            let file = AgentBridge.directory.appendingPathComponent("lid-lease-\(UUID().uuidString)")
            try Data().write(to:file,options:.atomic)
            let process = Process(); process.executableURL = Bundle.main.executableURL
            process.arguments = ["--watch-lid",String(getpid()),file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); adoptLidWatcher(process, lease: file)
        } catch { self.error = error.localizedDescription }
    }
    /// Retain one owned helper until its exit and recovery record are checked.
    @discardableResult func adoptLidWatcher(_ process: any LidWatcherProcess, lease: URL) -> Bool {
        guard watcher == nil, !lidStopPending, !lidStopper.hasOutstandingFilesystemWork else { return false }
        watcher = process; self.lease = lease; keepClosed = true; lidStopFailed = false
        return true
    }
    func stopLid() {
        keepClosed = false
        guard let watcher else { return }
        if lidStopper.requestStop(process: watcher, lease: lease,
            journal: AgentBridge.directory.appendingPathComponent("lid-recovery.json")) {
            lidStopPending = true; lidStopFailed = false
        }
    }
    /// Only an explicit successful power repair can retire a failed helper.
    /// The caller must verify the normal power state, not merely delete a file.
    @discardableResult func completePowerRecovery(_ repair: () throws -> Void) rethrows -> Bool {
        guard !lidStopPending, !lidStopper.hasOutstandingFilesystemWork, watcher?.isRunning != true else { return false }
        try repair()
        watcher = nil; lease = nil; lidStopFailed = false
        return true
    }
    func setAmbient(_ enabled: Bool) {
        guard !demo, device.available else { error = "A compatible live Mac is required."; return }
        if let app = device.competingApp { error = "Quit \(app) before changing logo settings."; return }
        let resume = controlWanted; controlWanted = false; releaseHardware()
        do { try RuntimeServices.authorizedAmbient(enabled); ambientUnlocked = enabled; defaults.set(enabled,forKey:"ambientUnlocked"); if resume { setControl(true) } }
        catch { self.error = error.localizedDescription }
    }
    var loginEnabled: Bool { !demo && SMAppService.mainApp.status == .enabled }
    func setLogin(_ value: Bool) {
        guard !demo else { return }
        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; objectWillChange.send() }
        catch { self.error = error.localizedDescription }
    }
    func connectAgent(_ agent: CodingAgent, _ enabled: Bool) {
        guard !demo else { notice = "Connections are disabled in isolated preview."; return }
        do { try AgentBridge.connect(agent,enabled:enabled); notice = enabled ? (agent == .codex ? "Hooks installed. Review and trust them in Codex Settings → Hooks, then start a new session." : "Hooks installed. Start a new Claude Code session to see signals.") : "Backlit's hooks were removed. Existing hooks were preserved."; objectWillChange.send() }
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
    func saveOBSScript() {
        guard !demo else { return }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("Integrations/obs/backlit_obs.py"),
              let data = try? Data(contentsOf: script) else { error = "The OBS script is missing from this build."; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "backlit_obs.py"
        panel.title = "Save OBS integration"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try data.write(to: destination, options: .atomic); notice = "Add the script in OBS → Tools → Scripts. Enable the local connection and select Signals in Backlit." }
        catch { self.error = error.localizedDescription }
    }
    func copyPairingKey() {
        guard !demo else { return }
        do { let token = try BridgeToken.value(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token,forType:.string); notice = "Pairing key copied. Paste it into Home Assistant; keep it private." }
        catch { self.error = error.localizedDescription }
    }
    func apiState() -> [String:Any] {
        ["id":id,"name":"Backlit","version":Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development","build":Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0","enabled":enabled,"brightness":Int(((mode == .battery ? output : Effects.clamp(brightness))*255).rounded()),
         "effect":mode.title,"effects":availableModes.map(\.title),"battery":Effects.percent(battery),
         "charging":charging,"actively_charging":activelyCharging,"agent_state":agents.isEmpty ? "no_recent_signals" : agentState.rawValue,
         "agent_sessions":agents.count,"hardware_supported":device.available,"controlling":controlling,
         "preview":!controlling,"paused":pausedReason ?? "","output":output,
         "battery_available":batteryAvailable,"charge_ready":chargeReady,"automation_enabled":automationsEnabled,
         "signal_category":signals.current?.category.rawValue ?? "","signal_state":signals.current?.state.rawValue ?? "",
         "signal_count":signalCount]
    }
    func resumeAfterUpdateFailure() {
        guard isStopping && terminationApproved else { return }
        isStopping = false; terminationApproved = false
        controlWanted = !demo && device.available && !device.needsRecovery
        startPowerMonitoring()
        if bridgeEnabled { configureBridge(enabled: true, lan: bridgeLAN) }
        configureTimer(); requestFrame()
        resumeAudioAfterUpdateFailure()
    }
    func quit() {
        guard updater.allowsTermination() else { error = updater.message; return }
        NSApp.terminate(nil)
    }
    func prepareQuit() -> Bool {
        if terminationApproved { return true }
        // Cocoa's terminateLater path keeps the run loop responsive while the
        // owned helper restores power. No hardware/quit decision is discarded.
        if watcher != nil || lidStopPending {
            stopLid()
            return false
        }
        if controlling && !enabled {
            let alert = NSAlert(); alert.messageText = "Leave the logo off?"; alert.informativeText = "You can leave it dark or restore the settings from before this Backlit session. A saved recovery remains available on the next launch."
            alert.addButton(withTitle:"Restore and Quit"); alert.addButton(withTitle:"Leave Off and Quit"); alert.addButton(withTitle:"Cancel")
            let result = alert.runModal(); if result == .alertThirdButtonReturn { return false }
            if result == .alertSecondButtonReturn { controlling = false }
        }
        audioSession.retainResumeIntent(consented: audioConsent)
        isStopping = true; synchronizeTouch(); synchronizeTyping(); powerMonitor.stop(); timer?.invalidate()
        stopLid(); releaseHardware()
        if controlling { isStopping=false; startPowerMonitoring(); synchronizeTouch(forceRestart: true); synchronizeTyping(forceRestart: true); configureTimer(); return false }
        timer?.invalidate(); bridge.stop(); stopAudio(); terminationApproved = true; return true
    }
}
