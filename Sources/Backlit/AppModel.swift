import AppKit
import SwiftUI
import ServiceManagement
import Combine

@MainActor final class LightPresentation: ObservableObject {
    @Published var level = 0.0
}

@MainActor final class AppModel: ObservableObject {
    let demo: Bool
    let defaults: UserDefaults
    let device: LogoDevice
    let audio = SystemAudio()
    let touch = TouchResponse()
    let touchSources = TouchResponse.sources
    var touchAvailable:Bool {!touchSources.isEmpty}
    @Published var touchSource:TouchSource = .screen {didSet {
        guard !isLoading else{return};defaults.set(touchSource.rawValue,forKey:"touch.source")
        if mode == .touch && enabled && !demo {_ = touch.start(source:touchSource)}
    }}
    @Published var touchClickBlink = false {didSet {if !isLoading {defaults.set(touchClickBlink,forKey:"touch.clickBlink")}}}
    private var touchBlinking = false
    private var blinkGeneration = 0
    @Published var touchDown = false
    @Published var touchStatus = "Waiting for touch"
    var availableModes:[GlowMode] {GlowMode.allCases.filter{$0 != .touch || touchAvailable}}
    let bridge = HomeBridge()
    @Published var batteryOptions = BatteryResponseOptions() { didSet {
        guard !isLoading else { return }
        if let data = try? JSONEncoder().encode(batteryOptions) { defaults.set(data, forKey: "battery.response") }
        batteryReadySignal.reset(); configureTimer(); requestFrame()
    } }
    private var batteryReadySignal = BatteryReadySignal()
    @Published var batterySignalActive = false
    @Published var mode: GlowMode = .battery { didSet { guard !isLoading else{return}; lastSourceSample = -Double.infinity; if mode == .battery {lastBatterySample = -Double.infinity}; save(); if mode != .music { stopAudio() } else if audioConsent { startAudio() }
        if mode == .touch && enabled && !demo { touchStatus = touch.start(source:touchSource) ? "Waiting for \(touchSource.title.lowercased()) touch" : "Touch events are unavailable on this macOS build" }
        else { touch.stop() }
        batteryReadySignal.reset(); configureTimer(); requestFrame() } }
    @Published var enabled = true { didSet {
        guard !isLoading else{return}
        defaults.set(enabled,forKey:"enabled")
        if !demo && device.available && !device.needsRecovery { controlWanted = true }
        if mode == .touch && !demo { if enabled { _ = touch.start(source:touchSource) } else { touch.stop() } }
        if !enabled && (audioRunning || audioStarting) {stopAudio()}
        else if enabled && mode == .music && audioConsent {startAudio()}
        requestFrame(); configureTimer()
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
    // Keep the existing API's charging field compatible: it means external power.
    @Published var charging = false
    @Published var activelyCharging = false
    @Published var batteryAvailable = false
    var batteryIsPulsing: Bool { batteryAvailable && charging && activelyCharging && battery < 1 && batteryOptions.chargingStyle == .breathe }
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
    private var audioGeneration = 0
    private var screenSleeping = false
    private var systemSleeping = false
    private var consoleActive = true
    private var watcher: Process?
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
            if batterySignalActive { return "Charge-ready signal" }
            if batteryIsPulsing { return "Pulsing while charging" }
            if charging && batteryOptions.chargingStyle != .level { return "Steady while plugged in" }
            return t("Following your battery","跟隨電量")
        case .music:return audioRunning ? "Moving with your music" : "Ready for your music"
        case .agents:return "Watching your agents"
        case .touch:return touchDown ? "Touching · light on" : "Ready for \(touchSource.title.lowercased()) touch"
        }
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    init(demo: Bool = false, defaults: UserDefaults? = nil) {
        self.demo = demo
        self.defaults = defaults ?? (demo ? UserDefaults(suiteName:"local.backlit.preview")! : .standard)
        device = LogoDevice(directory:AgentBridge.directory)
        if let data = self.defaults.data(forKey: "battery.response"),
           let options = try? JSONDecoder().decode(BatteryResponseOptions.self, from: data) { batteryOptions = options }
        if let raw = self.defaults.string(forKey:"mode"), let mode = GlowMode(rawValue:raw) { self.mode = mode }
        if self.defaults.object(forKey:"brightness") != nil { brightness = self.defaults.double(forKey:"brightness") }
        if self.defaults.object(forKey:"period") != nil { period = self.defaults.double(forKey:"period") }
        if self.defaults.object(forKey:"intensity") != nil { intensity = self.defaults.double(forKey:"intensity") }
        if let raw=self.defaults.string(forKey:"touch.source"),let source=TouchSource(rawValue:raw),touchSources.contains(source) {touchSource=source}
        else {touchSource=touchSources.first ?? .screen}
        if mode == .touch && !touchAvailable { mode = .steady }
        touchClickBlink = self.defaults.bool(forKey:"touch.clickBlink")
        strobe = self.defaults.bool(forKey:"strobe")
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
            if self.mode == .touch {self.cachedLocked=RuntimeServices.locked;self.tick()}
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
        audio.onFailure = { [weak self] text in Task { @MainActor in self?.audioRunning = false; self?.error = text } }
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
        for (name,action) in states { observers.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in Task { @MainActor in if let self { action(self) } }}) }
        controlWanted = !demo && device.available && !device.needsRecovery
        configureTimer()
        if !demo && enabled && mode == .touch {touchStatus=touch.start(source:touchSource) ? "Waiting for \(touchSource.title.lowercased()) touch" : "Touch events unavailable"}
        if !demo && !controlWanted && device.needsRecovery { notice = "A previous logo session needs restoration. Use Restore Light to pick up where you left off." }
        if !demo && self.defaults.bool(forKey:"bridge.enabled") { configureBridge(enabled:true,lan:self.defaults.bool(forKey:"bridge.lan")) }
        tick()
    }
    func save() {
        guard !isLoading else{return}
        defaults.set(mode.rawValue,forKey:"mode"); defaults.set(brightness,forKey:"brightness")
        defaults.set(period,forKey:"period"); defaults.set(intensity,forKey:"intensity"); defaults.set(strobe,forKey:"strobe")
        defaults.set(language,forKey:"language"); defaults.set(appearance,forKey:"appearance")
    }
    func tick() {
        guard !isStopping else { return }
        tickCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now-lastSourceSample >= 1 {
            lastSourceSample = now
            competingController = demo ? nil : device.competingApp
            if now-lastBatterySample >= (mode == .battery ? 1 : 15) {
                lastBatterySample=now
                updateBattery(demo ? RuntimeServices.BatterySnapshot(level: 0.82, externalPower: false, activelyCharging: false) : RuntimeServices.batterySnapshot())
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
            if mode == .touch && !demo {
                if nextPause != nil {touch.stop()}
                else if enabled {_ = touch.start(source:touchSource)}
            }
        }
        if nextPause != nil && touchDown { touch.reset() }
        var input = EffectInput()
        input.mode = mode; input.enabled = enabled; input.brightness = brightness; input.period = period
        input.battery = battery; input.batteryAvailable = batteryAvailable
        input.externalPower = charging; input.activelyCharging = activelyCharging
        input.batteryChargingStyle = batteryOptions.chargingStyle; input.batteryPulsePeriod = batteryOptions.pulsePeriod
        if mode == .battery && enabled && nextPause == nil && batteryAvailable {
            input.batteryCueLevel = batteryReadySignal.update(charge: battery, externalPower: charging, at: now, options: batteryOptions)
        } else { batteryReadySignal.reset() }
        if batterySignalActive != batteryReadySignal.active { batterySignalActive = batteryReadySignal.active }
        input.audio = audio.level; input.intensity = intensity; input.strobe = strobe
        input.agent = agentState; input.away = cachedAway
        // A deliberately selected physical light effect must not silently turn
        // into Steady because the owner reduces on-screen interface motion.
        input.touchDown = touchDown && !touchBlinking
        if demo && mode == .music { input.audio = 0.35 + 0.35 * sin((ProcessInfo.processInfo.systemUptime-epoch)*5) }
        let nextOutput = pausedReason == nil ? Effects.level(at:ProcessInfo.processInfo.systemUptime-epoch,input:input) : 0
        output = nextOutput
        if (demo || isPreviewVisible?() != false) && now-lastPreviewSample >= 0.1 && abs(presentation.level-nextOutput) > 0.005 { presentation.level = nextOutput; lastPreviewSample = now }
        if controlWanted && !demo {
            if pausedReason != nil { releaseHardware(); if audioRunning { stopAudio() } }
            else {
                do {
                    if !controlling { try device.begin(); controlling = true }
                    try device.apply(output)
                } catch { self.error = error.localizedDescription; controlWanted = false; releaseHardware() }
            }
        }
        onIconChange?()
        configureTimer()
        if let watcher, !watcher.isRunning { self.watcher = nil; keepClosed = false; error = "The closed-lid watcher stopped (\(watcher.terminationStatus)). Review power recovery in Settings." }
    }
    func requestFrame() {
        guard !framePending else { return }
        framePending = true
        DispatchQueue.main.async { [weak self] in self?.framePending=false;self?.tick() }
    }
    func configureTimer() {
        let animated = enabled && pausedReason == nil && (mode == .breathe || (mode == .battery && (batteryIsPulsing || batteryReadySignal.requiresAnimation)) || (mode == .music && audioRunning) || (mode == .agents && agentState != .waiting))
        let interval = animated ? 0.05 : 1.0
        guard timerInterval != interval || timer == nil else { return }
        timer?.invalidate(); timerInterval = interval
        let next=Timer(timeInterval:interval,repeats:true){[weak self] _ in MainActor.assumeIsolated{self?.tick()}}
        next.tolerance=animated ? 0.003 : 0.1
        RunLoop.main.add(next,forMode:.common);timer=next
    }
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
        controlWanted = false; stopLid()
        do { try device.restore(); controlling = false; try RuntimeServices.repairLid(); notice = "The saved logo and lid settings were restored." }
        catch { self.error = error.localizedDescription }
    }
    func startAudio() {
        guard mode == .music, enabled, !audioStarting, !audioRunning else { return }
        if demo { notice = "Preview uses a sample waveform. Live system audio is never started in preview."; return }
        audioGeneration += 1; let generation = audioGeneration; audioStarting = true; audioPermissionHelp=false
        Task {
            do {
                try await audio.start()
                if generation != audioGeneration || mode != .music { await audio.stop() }
                else { audioRunning = true; audioConsent = true }
            } catch { self.audioPermissionHelp=true; self.error = SystemAudio.friendly(error).localizedDescription }
            audioStarting = false
        }
    }
    func openAudioPrivacy() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func stopAudio() {
        audioGeneration += 1; audioRunning = false
        Task { await audio.stop() }
    }
    func setLid(_ enabled: Bool) {
        guard !demo else { notice = "Closed-lid operation is unavailable in isolated preview."; return }
        if !enabled { stopLid(); return }
        guard controlling, device.competingApp == nil else { error = "Your logo needs to be ready before starting a closed-lid session."; return }
        do {
            try FileManager.default.createDirectory(at:AgentBridge.directory,withIntermediateDirectories:true)
            let file = AgentBridge.directory.appendingPathComponent("lid-lease-\(UUID().uuidString)")
            try Data().write(to:file,options:.atomic)
            let process = Process(); process.executableURL = Bundle.main.executableURL
            process.arguments = ["--watch-lid",String(getpid()),file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); lease = file; watcher = process; keepClosed = true
        } catch { self.error = error.localizedDescription }
    }
    func stopLid() {
        if let lease { try? FileManager.default.removeItem(at:lease) }
        if let watcher, watcher.isRunning { watcher.waitUntilExit() }
        watcher = nil; lease = nil; keepClosed = false
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
    func copyPairingKey() {
        guard !demo else { return }
        do { let token = try BridgeToken.value(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token,forType:.string); notice = "Pairing key copied. Paste it into Home Assistant; keep it private." }
        catch { self.error = error.localizedDescription }
    }
    func apiState() -> [String:Any] {
        ["id":id,"name":"Backlit","version":"0.1.9","enabled":enabled,"brightness":Int((Effects.clamp(brightness)*255).rounded()),
         "effect":mode.title,"effects":availableModes.map(\.title),"battery":Int((battery*100).rounded()),
         "charging":charging,"actively_charging":activelyCharging,"battery_available":batteryAvailable,"agent_state":agents.isEmpty ? "no_recent_signals" : agentState.rawValue,
         "agent_sessions":agents.count,"hardware_supported":device.available,"controlling":controlling,
         "preview":!controlling,"paused":pausedReason ?? "","output":output]
    }
    func quit() { if prepareQuit() { NSApp.terminate(nil) } }
    func prepareQuit() -> Bool {
        if terminationApproved { return true }
        if controlling && !enabled {
            let alert = NSAlert(); alert.messageText = "Leave the logo off?"; alert.informativeText = "You can leave it dark or restore the settings from before this Backlit session. A saved recovery remains available on the next launch."
            alert.addButton(withTitle:"Restore and Quit"); alert.addButton(withTitle:"Leave Off and Quit"); alert.addButton(withTitle:"Cancel")
            let result = alert.runModal(); if result == .alertThirdButtonReturn { return false }
            if result == .alertSecondButtonReturn { controlling = false }
        }
        isStopping = true; touch.stop(); timer?.invalidate()
        stopLid(); releaseHardware()
        if controlling { isStopping=false; configureTimer(); return false }
        timer?.invalidate(); bridge.stop(); stopAudio(); terminationApproved = true; return true
    }
}
