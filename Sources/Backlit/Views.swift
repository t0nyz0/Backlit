import SwiftUI
import AppKit
import Carbon

struct Surface<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String = "", @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            if !title.isEmpty { Text(title).font(.system(size:14,weight:.semibold)) }
            content
        }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(Color.primary.opacity(0.07),lineWidth:1))
    }
}

/// The live state belongs beside the control heading, not below the effect controls.
/// Long recovery messages wrap rather than disappearing into a truncated badge.
struct LogoControlHeading: View {
    let title: String
    let status: String
    let detail: String
    let controlling: Bool
    private var label: some View {
        HStack(spacing: 5) {
            Circle().fill(controlling ? Color.green : .white.opacity(0.45)).frame(width: 5, height: 5)
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5)
        }.fixedSize()
    }
    private var state: some View { Text(status).font(.system(size: 12, weight: .medium)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { label; state.fixedSize() }
                VStack(alignment: .leading, spacing: 5) {
                    label
                    state.fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("logo-control-heading")
    }
}

struct LogoPreview: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: LightPresentation
    var compact = false
    init(model:AppModel,compact:Bool=false) { self.model=model;self.presentation=model.presentation;self.compact=compact }
    var statusHeading: LogoControlHeading {
        LogoControlHeading(title: model.l(model.controlling ? "LOGO CONTROL" : "LIVE PREVIEW"),
            status: model.l(model.status),
            detail: model.l(model.device.available ? "Compatible illuminated logo detected" : model.device.explanation),
            controlling: model.controlling)
    }
    var body: some View {
        ZStack {
            LidCanvas(level:presentation.level,compact:compact).clipShape(RoundedRectangle(cornerRadius:compact ? 18 : 24))
            VStack {
                HStack(alignment: .top, spacing: 14) {
                    if compact {
                        HStack(spacing: 5) {
                            Circle().fill(model.controlling ? Color.green : .white.opacity(0.45)).frame(width: 5, height: 5)
                            Text(model.l(model.controlling ? "LOGO CONTROL" : "LIVE PREVIEW")).font(.system(size: 9, weight: .semibold)).tracking(1.5)
                        }
                        Spacer()
                    } else {
                        statusHeading
                        VStack(alignment: .trailing, spacing: 10) {
                            Toggle(model.t("Logo on","標誌開啟"),isOn:$model.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small).help(model.lf("Turn logo output on or off · {shortcut}", arguments:["shortcut":model.shortcutLabel]))
                            if !model.demo && model.needsLightRecovery && (!model.controlWanted || !model.controlling) {
                                Button(model.t("Restore Light","還原燈光")){model.repairAndResume()}.buttonStyle(.bordered).controlSize(.small)
                            } else if !model.demo && model.savedLidPauseNeedsReview {
                                Button(model.l("Review Closed-lid Pause")) { model.selectedPage = "settings" }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                Spacer()
                HStack { Text(model.l(model.mode.title)).font(.system(size:11,weight:.medium)); Spacer(); if !model.controlling {Text(model.l("Logo unchanged")).font(.system(size:10)).opacity(0.6)} }
            }.foregroundStyle(.white.opacity(0.85)).padding(18)
        }.frame(height:compact ? 210 : 234)
            .accessibilityElement(children:.contain).accessibilityLabel(model.lf("{mode} brightness preview, {value} percent. {status}", arguments:["mode":model.l(model.mode.title),"value":model.formattedInteger(Effects.percent(presentation.level)),"status":model.l(model.controlling ? "Logo control enabled" : "Preview only")]))
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:28) {
                HStack(spacing:10) { BrandGlyph(); VStack(alignment:.leading,spacing:3) { Text("Backlit").font(.system(size:20,weight:.semibold)); Text("MACBOOK PROLED\nLOGO CONTROL").font(.system(size:7.5,weight:.medium)).tracking(1) } }.padding(.top,15)
                VStack(spacing:6) {
                    nav("light",model.t("Your light","你的光芒"),"sun.max")
                    nav("connections",model.t("Connections","連接"),"point.3.connected.trianglepath.dotted")
                    nav("settings",model.t("Settings","設定"),"slider.horizontal.3")
                }
                Spacer()
                VStack(alignment:.leading,spacing:8) {
                    Label(model.l(model.demo ? "ISOLATED PREVIEW" : model.controlling ? "LOGO CONNECTED" : model.hardwareFailure != nil ? "LOGO UNAVAILABLE" : "PREVIEW MODE"),systemImage:model.controlling ? "checkmark.circle.fill" : "circle.dotted").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                    Text("Backlit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")").font(.system(size:10)).foregroundStyle(.tertiary).padding(.top,10)
                }.padding(.bottom,8)
            }.padding(22).frame(width:200).background(Color(nsColor:.windowBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    if model.selectedPage == "light" { LightPage(model:model) }
                    else if model.selectedPage == "connections" { ConnectionsPage(model:model) }
                    else { SettingsPage(model:model) }
                }.padding(34).frame(maxWidth:980)
            }.background(BacklitPalette.canvas)
        }.frame(minWidth:1020,minHeight:760)
            .preferredColorScheme(model.colorScheme).environment(\.locale, model.formattingLocale)
            .alert("Backlit",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})){ if model.audioPermissionHelp {Button(model.l("Open Privacy Settings")){model.openAudioPrivacy();model.error=nil}}; Button(model.l("OK")){model.error=nil} } message:{Text(model.localizedError)}
            .overlay(alignment:.bottom) {
                if let notice = model.notice {
                    HStack { Image(systemName:"info.circle.fill"); Text(model.l(notice)).font(.system(size:12)); Button {model.notice=nil} label:{Image(systemName:"xmark")} .buttonStyle(.plain).accessibilityLabel(model.l("Dismiss notice")) }
                        .padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)).shadow(color:.black.opacity(0.08),radius:15).padding(18).frame(maxWidth:750)
                }
            }
    }
    func nav(_ id: String,_ title: String,_ icon: String) -> some View {
        Button { model.selectedPage=id } label: {
            HStack(spacing:10) {Image(systemName:icon).frame(width:20);Text(title).lineLimit(1).minimumScaleFactor(0.85);Spacer()}.font(.system(size:13,weight:model.selectedPage == id ? .semibold : .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal,12).padding(.vertical,11)
                .foregroundStyle(model.selectedPage == id ? Color(nsColor:.windowBackgroundColor) : Color.primary.opacity(0.65))
                .background(model.selectedPage == id ? Color.primary : .clear,in:RoundedRectangle(cornerRadius:10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment:.leading,spacing:9){ Text(eyebrow).font(.system(size:10,weight:.semibold)).tracking(2).foregroundStyle(.secondary); Text(title).font(.system(size:31,weight:.semibold)).tracking(-0.9); Text(subtitle).font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) } }
}

struct BatteryOutputReadout: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: LightPresentation
    var compact: Bool
    init(model: AppModel, compact: Bool = false) {
        self.model = model; self.presentation = model.presentation; self.compact = compact
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.formattedPercent(presentation.level))
                .font(.system(size: compact ? 18 : 38, weight: .medium)).monospacedDigit()
                .accessibilityLabel(model.l("Actual battery-driven logo output"))
                .accessibilityValue(model.lf("{value} percent", arguments:["value":model.formattedInteger(Effects.percent(presentation.level))]))
            Text(model.l("Matches battery charge when unplugged."))
                .font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
        }
    }
}

/// Menu and workspace always present completeness together with the summary.
struct AgentSessionSummary: View {
    @ObservedObject var model: AppModel
    var compact = false
    var body: some View {
        let status = model.agentSessionStatus
        VStack(alignment: .leading, spacing: 6) {
            Label(summary(status), systemImage: "terminal")
                .font(.system(size: compact ? 11 : 13, weight: compact ? .regular : .medium))
                .foregroundStyle(compact ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = status.warning {
                Text(model.l(warning)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func summary(_ status: AgentSessionStatus) -> String {
        guard status.observedCount > 0 else {
            return model.l(status.incomplete ? "Session snapshot incomplete" : "Waiting for an agent")
        }
        let state = model.l(status.observedState.rawValue.capitalized)
        if compact && !status.incomplete { return state }
        return model.lf(status.incomplete ? "Observed sessions: {count} · {state}" : "Sessions: {count} · {state}",
            arguments: ["count": model.formattedInteger(status.observedCount), "state": state])
    }
}

struct LightPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        LogoPreview(model:model)
        HStack(alignment:.top,spacing:18) {
            Surface(model.t("Behavior","選擇模式")) {
                VStack(spacing:5) { ForEach(model.presentedModes) { mode in modeRow(mode) } }
            }.frame(maxWidth:.infinity)
            VStack(spacing:18) {
                if model.mode == .battery {
                    Surface(model.l("Battery-driven output")) { BatteryOutputReadout(model: model) }
                } else {
                Surface(model.t("Brightness","亮度")) {
                    HStack(alignment:.firstTextBaseline,spacing:4) { Text(model.formattedPercent(model.brightness)).font(.system(size:38,weight:.medium)).monospacedDigit(); Spacer(); Image(systemName:"sun.max").font(.system(size:23,weight:.light)).foregroundStyle(.secondary) }
                    Slider(value:$model.brightness,in:0...1).tint(.primary).accessibilityLabel(model.l("Logo brightness"))
                    Text(model.t("Does not change your screen brightness setting.","不會更改螢幕亮度設定。" )).font(.system(size:11)).foregroundStyle(.secondary)
                }
                }
                Surface {
                    if model.mode == .breathe {
                        HStack {Text(model.t("Breathing pace","呼吸速度")).fontWeight(.medium);Spacer();Text(model.lf("{value} s", arguments:["value":model.formattedDecimal(model.period)])).monospacedDigit().foregroundStyle(.secondary)}
                        Slider(value:$model.period,in:Effects.breathingPeriodRange).tint(.primary).accessibilityLabel(model.l("Breathing cycle seconds"))
                        HStack {Text(model.l("Faster"));Spacer();Text(model.l("Slower"))}.font(.system(size:10)).foregroundStyle(.secondary)
                    } else if model.mode == .music {
                        MusicResponseControls(model: model)
                        HStack {Text(model.t("Beat intensity","節拍強度")).fontWeight(.medium);Spacer();Image(systemName:"waveform")}
                        Slider(value:$model.musicIntensityPosition,in:0...1).tint(.primary).accessibilityLabel(model.l("Music intensity"))
                        Toggle(model.t("Dark between beats","節拍之間熄滅"),isOn:$model.strobe).toggleStyle(.switch).controlSize(.small)
                        MusicCaptureStatus(model: model)
                    } else if model.mode == .battery {
                        Label("\(model.formattedPercent(model.battery)) · \(model.l(model.batteryPowerLabel))", systemImage: model.charging ? "bolt.battery" : "battery.75percent").font(.system(size: 14, weight: .medium))
                        BatterySettingsControls(model: model)
                    } else if model.mode == .agents {
                        AgentSessionSummary(model: model)
                        Text(model.l("A soft glow while idle. A pulse while working. Two blinks when an agent needs you and you're away.")).font(.system(size:12)).foregroundStyle(.secondary)
                        Button(model.l("Manage Connections")){model.selectedPage="connections"}
                    } else if model.mode == .typing {
                        Label(model.l("Light up while typing"), systemImage: "keyboard").font(.system(size: 13, weight: .medium))
                        TypingResponseControls(model: model)
                        Text(model.l("The light turns off shortly after typing stops. With the lid closed, use an external keyboard.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if model.mode == .touch {
                        Label(model.l(model.unavailableTouchMessage == nil ? model.touchStatus : "Trackpad input unavailable"),systemImage:"hand.tap").font(.system(size:12,weight:.medium))
                        if model.unavailableTouchMessage == nil && model.touchSource != .screen {Toggle(model.l("Blink on trackpad click"),isOn:$model.touchClickBlink).toggleStyle(.switch).controlSize(.small)}
                        TypingResponseControls(model: model)
                        if let message = model.unavailableTouchMessage {
                            Text(model.l(message)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        } else {
                            Text(model.l("Works with any app open. Rest a finger to light the logo; lift all fingers to turn it off.")).font(.system(size:11)).foregroundStyle(.secondary)
                            Text(model.l("Global trackpad · event-driven, no input polling")).font(.system(size:10)).foregroundStyle(.tertiary)
                        }
                    } else {
                        Label(model.t("Steady brightness","簡單、優雅地亮著。"),systemImage:"circle.fill").font(.system(size:13,weight:.medium))
                        Text(model.t("Uses the brightness set above.","以你選擇的亮度持續發光。")).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                }.font(.system(size:12))
            }.frame(maxWidth:.infinity)
        }
    }
    func modeRow(_ mode: GlowMode) -> some View {
        let selected = model.mode == mode
        let subtitles: [GlowMode:String] = [.steady:model.t("Constant brightness","持續而柔和的光"),.breathe:model.t("Fade in and out","跟隨你的呼吸節奏"),.battery:model.t("Follow battery charge","一眼掌握電量"),.music:model.t("Respond to system playback","隨音樂律動"),.agents:model.t("Coding agent status","工作需要你時提醒"),.touch:model.t("Trackpad and optional typing response","觸控板與選用打字回應"),.typing:model.t("Light up while typing","打字時亮起")]
        return Button {model.mode=mode} label: {
            HStack(spacing:12) {
                Image(systemName:mode.symbol).font(.system(size:17,weight:.medium)).frame(width:34,height:34).foregroundStyle(selected ? Color(nsColor:.windowBackgroundColor) : Color.primary.opacity(0.6)).background(selected ? Color.primary : Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:3){Text(model.l(mode.title)).font(.system(size:12,weight:.semibold));Text(model.l(mode == .touch && !model.touchAvailable ? "Input unavailable · choose another behavior" : subtitles[mode]!)).font(.system(size:10)).foregroundStyle(.secondary)}
                Spacer();if selected {Image(systemName:"checkmark").font(.system(size:11,weight:.bold))}
            }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                .contentShape(Rectangle())
                .background(selected ? Color.primary.opacity(0.045) : .clear,in:RoundedRectangle(cornerRadius:12))
        }.buttonStyle(.plain).disabled(!model.availableModes.contains(mode))
            .accessibilityLabel(model.lf("{mode} mode", arguments:["mode":model.l(mode.title)])).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(model.l(mode == .touch && !model.touchAvailable ? "Input unavailable. Enable typing response or choose another behavior." : ""))
    }
}

struct ConnectionsPage: View {
    @ObservedObject var model: AppModel
    @State private var showHomeSetup=false
    var body: some View {
        PageHeading(eyebrow: model.l("CONNECTIONS"), title: model.t("Assistants & integrations", "助理與整合"),
            subtitle: model.t("Control your light on request, or reflect coding activity automatically.", "依要求控制燈光，或自動反映程式工作狀態。"))
        MCPConnections(model: model)
        ConnectionSettingsSection(model.t("Coding status hooks", "程式狀態掛鉤"),
            detail: model.l("Automatic light feedback from coding sessions. Independent of MCP.")) {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionSettingsGroup {
                    ForEach(CodingAgent.allCases) { agent in
                        let installation = model.demo ? AgentHookInstallation.absent : AgentBridge.installation(agent)
                        let connected = installation.fullyInstalled
                        HStack(spacing: 12) {
                            Image(systemName: agent == .codex ? "sparkle" : "terminal")
                                .font(.system(size: 18)).frame(width: 36, height: 36)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(agent.title).font(.system(size: 13, weight: .semibold))
                                Text(model.l(connected ? (agent == .codex ? "Hooks installed · trust them in Codex" : "Hooks installed · start a new session") : installation.canDisconnect ? "Hooks need review · reconnect or check agent settings" : "Working, waiting, or needs your attention"))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Button { model.chooseFolder(agent) } label: { Image(systemName: "folder") }
                                .help(model.l("Choose a custom configuration folder"))
                                .accessibilityLabel(model.lf("Choose {agent} configuration folder", arguments:["agent":agent.title]))
                            if !connected {
                                Button(installation.canDisconnect ? model.t("Reconnect", "重新連接") : model.t("Connect", "連接")) {
                                    model.connectAgent(agent, true)
                                }.accessibilityLabel(model.lf(installation.canDisconnect ? "Reconnect {agent} coding status hooks" : "Connect {agent} coding status hooks", arguments:["agent":agent.title]))
                            }
                            if installation.canDisconnect {
                                Button(model.t("Disconnect", "中斷連接")) { model.connectAgent(agent, false) }
                                    .accessibilityLabel(model.lf("Disconnect {agent} coding status hooks", arguments:["agent":agent.title]))
                            }
                        }.padding(.vertical, 14).controlSize(.regular)
                        if agent == .claude { Divider() }
                    }
                }
                if let warning = model.agentMetadataWarning { Text(model.l(warning)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                Text(model.l("Hooks send only a session identifier and a status. Your prompts, code, and tool output never enter Backlit."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
            }
        }.accessibilityIdentifier("coding-status-hooks-section")
        AutomationConnections(model: model)
        Surface {
            HStack(spacing:14) {
                Image(systemName:"house").font(.system(size:20)).frame(width:42,height:42)
                VStack(alignment:.leading,spacing:4){Text("Home Assistant").font(.system(size:14,weight:.semibold));Text(model.l("Optional local light integration")).font(.system(size:11)).foregroundStyle(.secondary)}
                Spacer();Toggle(model.l("Enable Home Assistant bridge"),isOn:Binding(get:{model.bridgeEnabled},set:{model.configureBridge(enabled:$0,lan:model.bridgeLAN)})).toggleStyle(.switch).labelsHidden()
            }
            DisclosureGroup(model.l("Setup"),isExpanded:$showHomeSetup) {
                VStack(alignment:.leading,spacing:12) {
                    Toggle(model.t("Allow connections from your local network","允許本地網路連接"),isOn:Binding(get:{model.bridgeLAN},set:{model.configureBridge(enabled:model.bridgeEnabled,lan:$0)})).toggleStyle(.switch).controlSize(.small)
                    Text(model.bridgeEnabled ? model.lf("{status} · port {port}", arguments: ["status":model.l(model.bridgeStatus),"port":"48261"]) : model.l("Off by default. Enable network access for Home Assistant on another device.")).font(.system(size:11)).foregroundStyle(.secondary)
                    HStack {
                        Button(model.l("Copy Pairing Key")){model.copyPairingKey()}.disabled(!model.bridgeEnabled)
                        Button(model.l("New Pairing Key")){model.regeneratePairingKey()}.disabled(model.demo)
                            .help(model.l("Replace the pairing key if it may have been seen by someone else"))
                        Button(model.l("Integration Folder")) {if let folder=Bundle.main.resourceURL?.appendingPathComponent("HomeAssistant"){NSWorkspace.shared.open(folder)}}
                        Spacer();Link(model.l("Setup guide"),destination:URL(string:"https://github.com/t0nyz0/Backlit/blob/main/docs/HOME-ASSISTANT.md")!)
                    }.font(.system(size:11))
                }.padding(.top,10)
            }.font(.system(size:12))
        }

    }
    func useCase(_ symbol: String,_ title: String,_ detail: String) -> some View { VStack(alignment:.leading,spacing:9){Image(systemName:symbol).font(.system(size:20,weight:.light));Text(title).font(.system(size:12,weight:.semibold));Text(detail).font(.system(size:11)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading) }
}

struct SettingsPage: View {
    @ObservedObject var model: AppModel
    var languageSelection: Binding<String> {
        Binding(get: { model.language == "system" || AppLanguage(rawValue: model.language) != nil ? model.language : "en" },
                set: { model.language = $0 })
    }
    var body: some View {
        Text(model.t("Settings","設定")).font(.system(size:31,weight:.semibold))
        Surface(model.t("General","融入你的 Mac")) {
            settingRow("Appearance","Follow your Mac, or choose a look.") {Picker(model.l("Appearance"),selection:$model.appearance){Text(model.l("System")).tag("system");Text(model.l("Light")).tag("light");Text(model.l("Dark")).tag("dark")}.labelsHidden().frame(width:150)}
            Divider()
            settingRow(model.l("Language"), model.lf("Currently using {language}", arguments: ["language": model.resolvedLanguage.nativeName])) {
                Picker(model.l("Language"), selection: languageSelection) {
                    Text(model.l("System Default")).tag("system")
                    Divider()
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                }.labelsHidden().frame(minWidth: 180, idealWidth: 205)
                    .accessibilityHint(model.l("Follow your Mac’s preferred languages, or choose a language for Backlit."))
            }
            Divider()
            settingRow("Hide Dock icon", "Keep Backlit in the menu bar. Hiding the menu bar icon restores the Dock icon first.") {
                Toggle(model.l("Hide Dock icon"), isOn: Binding(get: { !model.dockIconVisible }, set: { model.dockIconVisible = !$0 }))
                    .labelsHidden().toggleStyle(.switch).disabled(!model.menuBarIconVisible)
            }
            Divider()
            settingRow("Show menu bar icon", "When hidden, reopen Backlit from the Dock or Applications. Settings stays available from the app menu.") {
                Toggle(model.l("Show menu bar icon"), isOn: $model.menuBarIconVisible).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            settingRow(model.t("Open at login","登入時開啟"),"Keep Backlit a click away in the menu bar.") {Toggle(model.l("Open at login"),isOn:Binding(get:{model.loginEnabled},set:{model.setLogin($0)})).labelsHidden().toggleStyle(.switch)}
            Divider()
            LogoShortcutControls(model:model)
        }
        Surface(model.t("Logo and power","進階控制")) {
            settingRow(model.t("Keep logo on with lid closed","闔上螢幕時保持發光"),model.t("Keeps this Mac awake and may leave its built-in screen lit while closed. Limited to 30 minutes; also stops for low battery, heat or Low Power Mode. Keep it on a hard, ventilated surface, never in a bag.","闔蓋時 Mac 保持喚醒，內建螢幕可能仍亮著。最長 30 分鐘；電量不足、過熱或開啟低耗電模式時也會停止。請放在通風的硬質平面上，切勿放入袋中。")) {Toggle(model.l("Keep logo on with lid closed"),isOn:Binding(get:{model.lidRequested},set:{model.setLid($0)})).labelsHidden().toggleStyle(.switch)}
            Text(model.l(model.lidPreferenceStatus)).font(.system(size: 11)).foregroundStyle(.secondary)
            LidDurationControls(model: model)
            Divider()
            settingRow(model.t("Override ambient brightness limit","任何環境下的全亮度"),"Optional ambient-light override. macOS asks for administrator approval. Your previous limits are saved.") {Toggle(model.l("Override ambient brightness limit"),isOn:Binding(get:{model.ambientUnlocked},set:{model.setAmbient($0)})).labelsHidden().toggleStyle(.switch)}
            if !model.demo && (model.needsLightRecovery || model.savedLidPauseNeedsReview) && (!model.controlWanted || !model.controlling) {
                Divider()
                settingRow(model.t("Restore your light","還原你的燈光"), model.savedLidRecoveryUnconfirmed
                    ? "Request restoration. Native handback remains unconfirmed; your saved closed-lid choice stays paused."
                    : "Finish recovering the previous session and reconnect.") {Button(model.t("Restore Light","還原燈光")){model.repairAndResume()}}
            }
        }
        Surface {
            HStack(spacing:14) {BrandGlyph(size:52);VStack(alignment:.leading,spacing:4){Text("Backlit").font(.system(size:18,weight:.semibold));Text(model.lf("Version {version} · t0nyz", arguments:["version":Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"])).font(.system(size:11)).foregroundStyle(.secondary)};Spacer();UpdateControls(updater: model.updater, preview: model.demo, localize: model.l)}
            Divider()
            HStack {Link("GitHub ↗",destination:URL(string:"https://github.com/t0nyz0/Backlit")!);Text("·").foregroundStyle(.tertiary);Link("t0nyz.com ↗",destination:URL(string:"https://t0nyz.com")!);Spacer();Link(model.l("☕ Buy me a coffee"),destination:URL(string:"https://buymeacoffee.com/tonyz")!)}.font(.system(size:12))
        }
        Text(model.l("The logo hardware produces white light. Backlit changes its brightness and rhythm, never the screen brightness. ")).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }
    func settingRow<Accessory:View>(_ title: String,_ subtitle: String,@ViewBuilder accessory:()->Accessory) -> some View {
        HStack(spacing:22){VStack(alignment:.leading,spacing:5){Text(model.l(title)).font(.system(size:13,weight:.medium)).fixedSize(horizontal:false,vertical:true);Text(model.l(subtitle)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)};Spacer(minLength:20);accessory()}
    }
}

struct LidDurationControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("Closed-lid duration", "闔蓋持續時間")).fontWeight(.medium)
            HStack(spacing: 8) {
                Text(model.t("Keep on for", "保持開啟"))
                Spacer()
                TextField(model.t("Duration", "持續時間"), value: Binding(
                    get: { model.lidSessionDuration.amount }, set: { model.setLidDuration(amount: $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 65)
                    .accessibilityLabel(model.t("Closed-lid duration amount", "闔蓋持續時間數值"))
                Stepper(model.t("Duration", "持續時間"), value: Binding(
                    get: { model.lidSessionDuration.amount }, set: { model.setLidDuration(amount: $0) }), in: 1...30).labelsHidden()
                Text(model.t("minutes", "分鐘"))
            }
            Text(model.t("Maximum 30 minutes per closure. Sleep counts toward the timer; relaunching does not reset it. This limit does not guarantee safe temperatures.", "每次闔蓋最長 30 分鐘。睡眠時間也會計入，重新開啟 App 不會重設計時器。此限制並不保證溫度安全。"))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .disabled(!model.canEditLidDuration)
        if !model.canEditLidDuration {
            Text(model.t("Turn off the closed-lid session and let cleanup finish before changing its duration.", "請先關閉闔蓋功能並等待還原完成，再更改持續時間。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var prompt = "Waiting for keys…"
    var capture: (LogoShortcut)->Void
    var invalid: (String)->Void
    var cancel: ()->Void
    func makeNSView(context:Context)->KeyView {let view=KeyView();updateNSView(view,context:context);return view}
    func updateNSView(_ view:KeyView,context:Context){view.prompt=prompt;view.needsDisplay=true;view.setAccessibilityLabel(prompt);view.capture=capture;view.invalid=invalid;view.cancel=cancel}
    final class KeyView:NSView {
        var prompt = "Waiting for keys…"
        var capture:((LogoShortcut)->Void)?
        var invalid:((String)->Void)?
        var cancel:(()->Void)?
        override var acceptsFirstResponder:Bool {true}
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();DispatchQueue.main.async { [weak self] in if let self {self.window?.makeFirstResponder(self)} }}
        override func keyDown(with event:NSEvent) {
            if event.keyCode == 53, event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty {cancel?();return}
            do {capture?(try LogoShortcut.capture(event))} catch {invalid?(error.localizedDescription)}
        }
        override func performKeyEquivalent(with event:NSEvent)->Bool {keyDown(with:event);return true}
        override func draw(_ dirtyRect:NSRect){(prompt as NSString).draw(in:NSRect(x:12,y:20,width:bounds.width-24,height:44),withAttributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.secondaryLabelColor])}
    }
}

/// Small instrument-style lid preview; the menu remains a compact control strip.
struct MenuLidPreview: View {
    @ObservedObject var presentation:LightPresentation
    let language: AppLanguage
    var formattingLocale: Locale = .autoupdatingCurrent
    var accessibilityText: String {
        Localization.format(Localization.text("Logo preview, {value} percent", language: language),
            arguments: ["value": Effects.percent(presentation.level).formatted(.number.locale(formattingLocale))])
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:8).fill(LinearGradient(colors:[Color(white:0.30),Color(white:0.13)],startPoint:.topLeading,endPoint:.bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.25),lineWidth:0.6))
            MenuLightMark(level: presentation.level)
            VStack {Spacer();Capsule().fill(.white.opacity(0.22)).frame(height:1).padding(.horizontal,14).padding(.bottom,4)}
        }.frame(width:88,height:60).accessibilityLabel(accessibilityText)
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:10) {
                BrandGlyph(size:30)
                VStack(alignment:.leading,spacing:2) { Text("Backlit").font(.system(size:16,weight:.semibold));Text(model.t("MacBook PROLED Logo Control","MacBook 標誌控制")).font(.system(size:10)).foregroundStyle(.secondary) }
                Spacer()
                Button {model.openWindow?()} label:{Image(systemName:"arrow.up.right.square").font(.system(size:15))}.buttonStyle(.plain).help(model.l("Open workspace")).accessibilityLabel(model.l("Open workspace"))
            }
            Divider()
            HStack(spacing:12) {
                MenuLidPreview(presentation:model.presentation, language:model.resolvedLanguage, formattingLocale:model.formattingLocale)
                VStack(alignment:.leading,spacing:4) {Text(model.t("Backlight","背光")).font(.system(size:13,weight:.semibold));Text(model.l(model.status)).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
                Spacer();Toggle(model.l("Backlight"),isOn:$model.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Text(model.t("Behavior","模式")).font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                Picker(model.l("Behavior"),selection:$model.mode) {ForEach(model.presentedModes){mode in Label(model.l(mode == .touch && !model.touchAvailable ? "Trackpad · unavailable" : mode.title),systemImage:mode.symbol).tag(mode).disabled(!model.availableModes.contains(mode))}}.labelsHidden().pickerStyle(.menu).frame(width:150)
            }
            if model.mode == .battery {
                Text(model.l("Battery-driven output")).font(.system(size: 12, weight: .medium))
                BatteryOutputReadout(model: model, compact: true)
            } else {
            VStack(spacing:10) {
                HStack {Text(model.t("Brightness","亮度")).font(.system(size:12,weight:.medium));Spacer();Text(model.formattedPercent(model.brightness)).font(.system(size:12)).monospacedDigit().foregroundStyle(.secondary)}
                HStack(spacing:10) {Image(systemName:"sun.min");Slider(value:$model.brightness,in:0...1).tint(.primary).accessibilityLabel(model.l("Logo brightness"));Image(systemName:"sun.max")}.font(.system(size:12)).foregroundStyle(.secondary)
            }
            }
            if model.mode == .breathe {
                VStack(spacing:8) {HStack {Text(model.t("Breathing pace","呼吸速度"));Spacer();Text(model.lf("{value} s", arguments:["value":model.formattedDecimal(model.period)])).monospacedDigit().foregroundStyle(.secondary)}.font(.system(size:11));Slider(value:$model.period,in:Effects.breathingPeriodRange).tint(.primary).accessibilityLabel(model.l("Breathing cycle seconds"))}
            } else if model.mode == .music {
                MusicResponseControls(model: model).font(.system(size:11))
                VStack(spacing:8) {HStack{Text(model.l("Beat intensity"));Slider(value:$model.musicIntensityPosition,in:0...1).tint(.primary).accessibilityLabel(model.l("Music intensity"))};Toggle(model.l("Dark between beats"),isOn:$model.strobe).toggleStyle(.switch).controlSize(.small);MusicCaptureStatus(model: model)}.font(.system(size:11))
            } else if model.mode == .battery {
                Label("\(model.formattedPercent(model.battery)) · \(model.l(model.batteryPowerLabel))",systemImage:"battery.75percent").font(.system(size:11)).foregroundStyle(.secondary)
            } else if model.mode == .typing {
                TypingResponseControls(model: model).font(.system(size: 11))
            } else if model.mode == .touch {
                TypingResponseControls(model: model).font(.system(size:11))
                VStack(alignment:.leading,spacing:8) {if model.touchSource != .screen {Toggle(model.l("Blink on click"),isOn:$model.touchClickBlink).toggleStyle(.switch).controlSize(.small)};Label(model.l(model.unavailableTouchMessage ?? model.touchStatus),systemImage:"hand.tap").fixedSize(horizontal:false,vertical:true).font(.system(size:11)).foregroundStyle(.secondary)}
            } else if model.mode == .agents {
                AgentSessionSummary(model: model, compact: true)
            }
            if !model.demo && model.needsLightRecovery && (!model.controlWanted || !model.controlling) {
                Button(model.t("Restore Light","還原燈光")){model.repairAndResume()}.buttonStyle(.borderedProminent).tint(.primary)
            }
            Divider()
            HStack {
                Button {model.selectedPage="settings";model.openWindow?()} label:{Label(model.t("Settings","設定"),systemImage:"gearshape")}.buttonStyle(.plain)
                Spacer();Text(model.shortcutLabel).font(.system(size:10)).foregroundStyle(.tertiary)
                Button(model.l("Quit")){model.quit()}.buttonStyle(.plain).padding(.leading,10)
            }.font(.system(size:11))
        }.padding(20).frame(width:320).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(model.colorScheme).environment(\.locale, model.formattingLocale)
    }
}
