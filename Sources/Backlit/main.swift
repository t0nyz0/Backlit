import AppKit
import SwiftUI
import Carbon
import IOKit

let arguments = CommandLine.arguments
func option(_ key: String) -> String? {
    guard let i = arguments.firstIndex(of:key), arguments.count > i+1 else { return nil }; return arguments[i+1]
}
if arguments.contains("--quit-running") {
    DistributedNotificationCenter.default().postNotificationName(.init("local.backlit.quit"),object:nil,userInfo:nil,deliverImmediately:true)
    let deadline = ProcessInfo.processInfo.systemUptime + 12
    while NSRunningApplication.runningApplications(withBundleIdentifier:"local.backlit").contains(where:{$0.processIdentifier != getpid()}) {
        if ProcessInfo.processInfo.systemUptime > deadline {
            FileHandle.standardError.write(Data("Backlit is waiting for a quit or restoration decision. Finish it in the app, then retry.\n".utf8));exit(1)
        }
        Thread.sleep(forTimeInterval:0.1)
    }
    exit(0)
}
if let index = arguments.firstIndex(of:AgentBridge.marker), arguments.count > index+3 {
    do {
        guard let agent = CodingAgent(rawValue:arguments[index+1]) else { exit(1) }
        try AgentBridge.receive(agent:agent,state:arguments[index+2],session:arguments[index+3]); exit(0)
    } catch { exit(1) }
}
if arguments.contains("--watch-fade") {
    guard let request=FadeHelperArguments(arguments) else {exit(2)}
    exit(FadeRuntime.runHelper(request))
}
if arguments.contains("--watch-lid") {
    guard let request = LidWatcherArguments(arguments: arguments) else {
        FileHandle.standardError.write(Data("Invalid closed-lid helper arguments.\n".utf8)); exit(2)
    }
    exit(RuntimeServices.watchLid(parent: request.parent, lease: request.lease, durationSeconds: request.durationSeconds, intentID: request.intent))
}
if let operation = option("--ambient-helper") {
    do { guard ["enable","restore"].contains(operation) else { exit(2) }; try RuntimeServices.ambientHelper(enabled:operation == "enable"); exit(0) }
    catch { FileHandle.standardError.write(Data(error.localizedDescription.utf8)); exit(1) }
}
if arguments.contains("--verify-hardware") {
    let directory = AgentBridge.directory.appendingPathComponent("verification-"+UUID().uuidString)
    let device = LogoDevice(directory:directory)
    do {
        let original = device.mapping()
        let before = LogoDevice.telemetry()
        try device.begin()
        do {
            try device.applyLegacyMapping(0.12)
            Thread.sleep(forTimeInterval:0.25)
            let changed = device.mapping()
            let during = LogoDevice.telemetry()
            try device.restore()
            Thread.sleep(forTimeInterval:0.25)
            let restored = device.mapping()
            let after = LogoDevice.telemetry()
            guard let original, let changed, let restored, LogoDevice.equivalent(original,restored), abs(changed[0][1]-120) < 0.01 else { throw RuntimeServices.failure("Hardware readback did not match.") }
            print("PASS: logo mapping acknowledged 120 nits and exactly restored its prior curve. Physical emission is not established by this check.")
            let record:[String:Any] = ["before":before,"during":during,"after":after,"mapping_restored":true]
            print(String(data:try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
            try? FileManager.default.removeItem(at:directory)
            exit(0)
        } catch { try? device.restore(); throw error }
    } catch { FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8)); exit(1) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    let model = AppModel(demo:arguments.contains("--preview") || option("--capture-suite") != nil || Bundle.main.object(forInfoDictionaryKey: "BacklitIsolatedPreview") as? Bool == true)
    var window: NSWindow!
    let menuBarItem = MenuBarItemController<NSStatusItem>()
    var status: NSStatusItem? { menuBarItem.item }
    var popover = NSPopover()
    var iconCache:[Int:NSImage]=[:]
    var lastIconStep = -1
    var lastTooltipUpdate = -Double.infinity
    var lastTooltipStatus = ""
    var hotkey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var observing: NSObjectProtocol?
    var quitObserver: NSObjectProtocol?
    private var pendingTerminationReason: QuitReason?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        NSApp.setActivationPolicy(.regular)
        if let icon = ApplicationIcon.load() {
            NSApp.applicationIconImage = icon
            NSApp.dockTile.display()
        }
        buildMenus()
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = model.demo ? "Backlit — Preview" : "Backlit"; window.titlebarAppearsTransparent = true; window.delegate = self
        let hosting=NSHostingView(rootView:RootView(model:model))
        hosting.allowedTouchTypes = .direct
        window.contentView=hosting; window.center(); window.isReleasedWhenClosed = false
        model.openWindow = { [weak self] in self?.showWindow() }
        model.onIconChange = { [weak self] in self?.updateIcon() }
        model.isPreviewVisible = { [weak self] in
            guard let self else{return false}
            return !NSApp.isHidden && ((self.window.isVisible && !self.window.isMiniaturized && self.window.occlusionState.contains(.visible) && self.model.selectedPage == "light") || self.popover.isShown)
        }
        model.onMenuBarIconVisibilityChange = { [weak self] in self?.updateMenuBarVisibility() }
        updateMenuBarVisibility()
        popover.contentViewController = NSHostingController(rootView:MenuView(model:model)); popover.behavior = .transient
        updateIcon(); installShortcut()
        observing = NotificationCenter.default.addObserver(forName:.init("Backlit.Shortcut"),object:nil,queue:.main){[weak self] _ in Task { @MainActor in self?.installShortcut() }}
        quitObserver = DistributedNotificationCenter.default().addObserver(forName:.init("local.backlit.quit"),object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.model.quit() } }
        AutomationRouter.shared.handler = { [weak model] command in
            guard let model else { throw RuntimeServices.failure("Backlit is not ready.") }
            try model.performAutomation(command)
        }
        AutomationRouter.shared.enabled = model.automationsEnabled && !model.demo
        model.updater.recoverAfterFailure = { [weak model] in model?.resumeAfterUpdateFailure() }
        model.updater.installGate.prepare = { [weak model] in model?.prepareQuit() ?? false }
        model.onLidStopCompleted = { [weak self] safe in
            guard let self else { return }
            if let reason = self.pendingTerminationReason {
                self.pendingTerminationReason = nil
                NSApp.reply(toApplicationShouldTerminate: safe && self.model.prepareQuit(reason: reason))
            } else if safe { self.model.updater.continueApprovedInstallation() }
        }
        model.start()
        if let page = option("--page") {model.selectedPage=page}
        showWindow()
        if let directory = option("--capture-suite") {
            Task { await captureSuite(URL(fileURLWithPath:directory)) }
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls.prefix(8) {
            do { try AutomationRouter.shared.perform(AutomationCommand(url: url)) }
            catch { model.error = error.localizedDescription }
        }
    }
    func showWindow() {popover.performClose(nil);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard model.updater.allowsTermination() else { model.error = model.updater.message; return .terminateCancel }
        // The current AppleEvent belongs to this callback only. Preserve its
        // reason while asynchronous restoration runs inside terminateLater.
        let reason = pendingTerminationReason ?? QuitReason(appleEvent: NSAppleEventManager.shared().currentAppleEvent)
        if model.prepareQuit(reason: reason) { return .terminateNow }
        if model.lidStopPending { pendingTerminationReason = reason; return .terminateLater }
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    @objc func toggleMenu() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {model.enabled.toggle();return}
        if popover.isShown {popover.performClose(nil)}
        else if let button=status?.button {popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);popover.contentViewController?.view.window?.makeKey()}
    }
    func updateMenuBarVisibility() {
        if !model.menuBarIconVisible { popover.performClose(nil) }
        if menuBarItem.setVisible(model.menuBarIconVisible, create: {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self; item.button?.action = #selector(toggleMenu)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            return item
        }, remove: { NSStatusBar.system.removeStatusItem($0) }) {
            lastIconStep = -1; lastTooltipUpdate = -Double.infinity
            updateIcon()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func updateIcon() {
        guard status?.button != nil, model.visualUpdatesAllowed else { return }
        // Confirmed hardware-off overrides the requested effect. This is not
        // an optical brightness measurement. Cache at most 101 tiny images.
        let logoStatus = model.logoStatus
        let step = StatusIconGeometry.step(for: logoStatus.level)
        if step != lastIconStep {
            if iconCache[step] == nil { iconCache[step] = StatusIconGeometry.image(at: step) }
            status?.button?.image = iconCache[step]
            lastIconStep = step
        }
        let now=ProcessInfo.processInfo.systemUptime
        let tooltip = "Backlit · \(model.mode.title) · \(logoStatus.detail)"
        if now-lastTooltipUpdate>=1 {
            lastTooltipStatus=tooltip;lastTooltipUpdate=now
            status?.button?.toolTip=tooltip
        }
    }
    func installShortcut() {
        // An isolated preview must not claim a system-wide keyboard shortcut.
        guard !model.demo else { return }
        if let hotkey {UnregisterEventHotKey(hotkey)}
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(),{_,_,_ in Task { @MainActor in AppDelegate.shared?.model.enabled.toggle() }; return noErr},1,&spec,nil,&eventHandler)
        }
        let result = RegisterEventHotKey(model.shortcutKey,model.shortcutModifiers,EventHotKeyID(signature:0x424c4954,id:1),GetApplicationEventTarget(),0,&hotkey)
        if result != noErr {model.notice="The shortcut is already in use. Choose another in Settings."}
    }
    @objc func quit() {model.quit()}
    @objc func settings() {model.selectedPage="settings";showWindow()}
    func buildMenus() {
        let menu=NSMenu();let root=NSMenuItem();menu.addItem(root);let app=NSMenu();root.submenu=app
        let setting=NSMenuItem(title:"Settings…",action:#selector(settings),keyEquivalent:",");setting.target=self;app.addItem(setting)
        app.addItem(.separator());let quit=NSMenuItem(title:"Quit Backlit",action:#selector(quit),keyEquivalent:"q");quit.target=self;app.addItem(quit)
        let editRoot=NSMenuItem(title:"Edit",action:nil,keyEquivalent:"");let edit=NSMenu(title:"Edit");editRoot.submenu=edit
        for (name,selector,key) in [("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {edit.addItem(NSMenuItem(title:name,action:NSSelectorFromString(selector),keyEquivalent:key))}
        menu.addItem(editRoot);NSApp.mainMenu=menu
    }
    func capture(_ view:NSView,to file:URL) throws {
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw RuntimeServices.failure("Cannot capture native view.")}
        view.cacheDisplay(in:view.bounds,to:rep)
        guard let data=rep.representation(using:.png,properties:[:]) else {throw RuntimeServices.failure("Cannot encode native screenshot.")}
        try data.write(to:file,options:.atomic)
    }
    func captureSuite(_ directory:URL) async {
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            // Documentation captures include the full settings panel without
            // changing the normal app's window size.
            window.setContentSize(NSSize(width: 1100, height: 1120))
            model.language="en"
            model.mode = .battery; model.batteryOptions = BatteryResponseOptions(); model.enabled = true
            try await Task.sleep(nanoseconds:2_200_000_000)
            for appearance in ["light","dark"] {
                model.appearance=appearance
                for page in ["light","connections","settings"] {
                    model.selectedPage=page;model.notice=nil
                    try await Task.sleep(nanoseconds:500_000_000)
                    if page == "light" {
                        for _ in 0..<65 {
                            if model.output >= 0.55 {break}
                            try await Task.sleep(nanoseconds:100_000_000)
                        }
                    }
                    try capture(window.contentView!.superview!,to:directory.appendingPathComponent("\(page)-\(appearance).png"))
                }
            }
            model.appearance="light"
            // Capture the actual Battery preview at its sampled output.
            // This waits on the app's output; it does not alter the waveform.
            for _ in 0..<65 {
                if model.output >= 0.55 {break}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            let menu=NSHostingView(rootView:MenuView(model:model));menu.frame=NSRect(origin:.zero,size:menu.fittingSize)
            let owned=NSWindow(contentRect:menu.frame,styleMask:.borderless,backing:.buffered,defer:false);owned.contentView=menu;owned.orderFront(nil)
            try await Task.sleep(nanoseconds:400_000_000)
            try capture(owned.contentView!.superview!,to:directory.appendingPathComponent("menu-light.png"));owned.orderOut(nil)
            for (behavior, filename) in [(GlowMode.music, "music-light.png"), (.touch, "trackpad-light.png"), (.typing, "typing-light.png")] {
                model.mode = behavior; model.selectedPage = "light"; model.notice = nil
                try await Task.sleep(nanoseconds: 500_000_000)
                try capture(window.contentView!.superview!, to: directory.appendingPathComponent(filename))
            }
            model.selectedPage = "connections"; model.automationsEnabled = true
            try await Task.sleep(nanoseconds: 500_000_000)
            try capture(window.contentView!.superview!, to: directory.appendingPathComponent("connections-automation-light.png"))
            model.automationsEnabled = false
            let icon=NSHostingView(rootView:BrandGlyph(size:1024));icon.frame=NSRect(x:0,y:0,width:1024,height:1024)
            let iconWindow=NSWindow(contentRect:icon.frame,styleMask:.borderless,backing:.buffered,defer:false);iconWindow.contentView=icon;iconWindow.orderFront(nil)
            try await Task.sleep(nanoseconds:200_000_000)
            try capture(icon,to:directory.appendingPathComponent("icon.png"));iconWindow.orderOut(nil)
            if arguments.contains("--capture-marker-levels") {
                model.mode = .steady; model.selectedPage = "light"; model.notice = nil
                for appearance in ["light", "dark"] {
                    model.appearance = appearance
                    for (name, level) in [("off", 0.0), ("low", 0.01), ("mid", 0.5), ("high", 1.0)] {
                        model.brightness = level; model.enabled = level > 0
                        try await Task.sleep(nanoseconds: 300_000_000)
                        try capture(window.contentView!.superview!, to: directory.appendingPathComponent("marker-window-\(appearance)-\(name).png"))
                        let panel = NSHostingView(rootView: MenuView(model: model)); panel.frame = NSRect(origin: .zero, size: panel.fittingSize)
                        let owned = NSWindow(contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
                        owned.contentView = panel; owned.orderFront(nil)
                        try await Task.sleep(nanoseconds: 100_000_000)
                        try capture(owned.contentView!.superview!, to: directory.appendingPathComponent("marker-menu-\(appearance)-\(name).png"))
                        owned.orderOut(nil)
                    }
                }
            }
            print("Native preview screenshots captured in \(directory.path)")
        } catch { print("Capture failed: \(error)") }
        model.quit()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
