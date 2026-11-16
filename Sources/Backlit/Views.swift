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
        LogoControlHeading(title: model.controlling ? model.t("LOGO CONTROL", th:"กำลังควบคุมโลโก้") : model.t("LIVE PREVIEW", th:"ตัวอย่างสด"),
            status: model.display(model.status),
            detail: model.device.available ? model.t("Compatible illuminated logo detected", th:"พบโลโก้เรืองแสงที่รองรับ") : model.display(model.device.explanation),
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
                            Text(model.controlling ? model.t("LOGO CONTROL", th:"กำลังควบคุมโลโก้") : model.t("LIVE PREVIEW", th:"ตัวอย่างสด")).font(.system(size: 9, weight: .semibold)).tracking(1.5)
                        }
                        Spacer()
                    } else {
                        statusHeading
                        VStack(alignment: .trailing, spacing: 10) {
                            Toggle(model.t("Logo on","標誌開啟","เปิดโลโก้"),isOn:$model.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small).help(model.t("Turn logo output on or off", th:"เปิดหรือปิดไฟโลโก้") + " · \(model.shortcutLabel)")
                            if !model.demo && model.needsLightRecovery && (!model.controlWanted || !model.controlling) {
                                Button(model.t("Restore Light","還原燈光","กู้คืนไฟ")){model.repairAndResume()}.buttonStyle(.bordered).controlSize(.small)
                            } else if !model.demo && model.savedLidPauseNeedsReview {
                                Button(model.t("Review Closed-lid Pause", th:"ตรวจสอบการหยุดขณะพับจอ")) { model.selectedPage = "settings" }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                }
                Spacer()
                HStack { Text(model.display(model.mode.title)).font(.system(size:11,weight:.medium)); Spacer(); if !model.controlling {Text(model.t("Logo unchanged", th:"โลโก้จริงไม่เปลี่ยน")).font(.system(size:10)).opacity(0.6)} }
            }.foregroundStyle(.white.opacity(0.85)).padding(18)
        }.frame(height:compact ? 210 : 234)
            .accessibilityElement(children:.contain).accessibilityLabel(model.t("\(model.mode.title) brightness preview, \(Effects.percent(presentation.level)) percent. \(model.controlling ? "Logo control enabled" : "Preview only")", th:"ตัวอย่างความสว่างแบบ\(model.display(model.mode.title)) \(Effects.percent(presentation.level)) เปอร์เซ็นต์ \(model.controlling ? "กำลังควบคุมโลโก้" : "แสดงตัวอย่างเท่านั้น")"))
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:28) {
                HStack(spacing:10) { BrandGlyph(); VStack(alignment:.leading,spacing:3) { Text("Backlit").font(.system(size:20,weight:.semibold)); Text("MACBOOK PROLED\nLOGO CONTROL").font(.system(size:7.5,weight:.medium)).tracking(1) } }.padding(.top,15)
                VStack(spacing:6) {
                    nav("light",model.t("Your light","你的光芒","ไฟของคุณ"),"sun.max")
                    nav("connections",model.t("Connections","連接","การเชื่อมต่อ"),"point.3.connected.trianglepath.dotted")
                    nav("settings",model.t("Settings","設定","การตั้งค่า"),"slider.horizontal.3")
                }
                Spacer()
                VStack(alignment:.leading,spacing:8) {
                    Label(model.demo ? model.t("ISOLATED PREVIEW", th:"โหมดตัวอย่าง (ไม่แตะฮาร์ดแวร์)") : model.controlling ? model.t("LOGO CONNECTED", th:"เชื่อมต่อโลโก้แล้ว") : model.hardwareFailure != nil ? model.t("LOGO UNAVAILABLE", th:"ใช้โลโก้ไม่ได้") : model.t("PREVIEW MODE", th:"โหมดตัวอย่าง"),systemImage:model.controlling ? "checkmark.circle.fill" : "circle.dotted").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
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
            .preferredColorScheme(model.colorScheme)
            .alert("Backlit",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})){ if model.audioPermissionHelp {Button(model.t("Open Privacy Settings", th:"เปิดการตั้งค่าความเป็นส่วนตัว")){model.openAudioPrivacy();model.error=nil}}; Button(model.t("OK", th:"ตกลง")){model.error=nil} } message:{Text(model.display(model.error ?? ""))}
            .overlay(alignment:.bottom) {
                if let notice = model.notice {
                    HStack { Image(systemName:"info.circle.fill"); Text(model.display(notice)).font(.system(size:12)); Button {model.notice=nil} label:{Image(systemName:"xmark")} .buttonStyle(.plain) }
                        .padding(14).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)).shadow(color:.black.opacity(0.08),radius:15).padding(18).frame(maxWidth:750)
                }
            }
    }
    func nav(_ id: String,_ title: String,_ icon: String) -> some View {
        Button { model.selectedPage=id } label: {
            HStack(spacing:10) {Image(systemName:icon).frame(width:20);Text(title);Spacer()}.font(.system(size:13,weight:model.selectedPage == id ? .semibold : .medium)).padding(.horizontal,12).padding(.vertical,11)
                .foregroundStyle(model.selectedPage == id ? Color(nsColor:.windowBackgroundColor) : Color.primary.opacity(0.65))
                .background(model.selectedPage == id ? Color.primary : .clear,in:RoundedRectangle(cornerRadius:10))
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
            Text("\(Effects.percent(presentation.level))%")
                .font(.system(size: compact ? 18 : 38, weight: .medium)).monospacedDigit()
                .accessibilityLabel(model.t("Actual battery-driven logo output", th:"ความสว่างโลโก้จริงตามแบตเตอรี่"))
                .accessibilityValue(model.t("\(Effects.percent(presentation.level)) percent", th:"\(Effects.percent(presentation.level)) เปอร์เซ็นต์"))
            Text(model.t("Matches battery charge when unplugged.", th:"เมื่อถอดปลั๊ก ความสว่างจะเท่ากับระดับแบตเตอรี่"))
                .font(.system(size: compact ? 10 : 11)).foregroundStyle(.secondary)
        }
    }
}

struct LightPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        LogoPreview(model:model)
        HStack(alignment:.top,spacing:18) {
            Surface(model.t("Behavior","選擇模式","รูปแบบไฟ")) {
                VStack(spacing:5) { ForEach(model.availableModes) { mode in modeRow(mode) } }
            }.frame(maxWidth:.infinity)
            VStack(spacing:18) {
                if model.mode == .battery {
                    Surface(model.t("Battery-driven output", th:"ความสว่างตามแบตเตอรี่")) { BatteryOutputReadout(model: model) }
                } else {
                Surface(model.t("Brightness","亮度","ความสว่าง")) {
                    HStack(alignment:.firstTextBaseline,spacing:4) { Text("\(Effects.percent(model.brightness))").font(.system(size:38,weight:.medium)).monospacedDigit(); Text("%").font(.system(size:19)).foregroundStyle(.secondary); Spacer(); Image(systemName:"sun.max").font(.system(size:23,weight:.light)).foregroundStyle(.secondary) }
                    Slider(value:$model.brightness,in:0...1).tint(.primary).accessibilityLabel(model.t("Logo brightness", th:"ความสว่างโลโก้"))
                    Text(model.t("Does not change your screen brightness setting.","不會更改螢幕亮度設定。","ไม่กระทบความสว่างของหน้าจอ")).font(.system(size:11)).foregroundStyle(.secondary)
                }
                }
                Surface {
                    if model.mode == .breathe {
                        HStack {Text(model.t("Breathing pace","呼吸速度","ความเร็วจังหวะหายใจ")).fontWeight(.medium);Spacer();Text(model.t(String(format:"%.1f s",model.period), th:String(format:"%.1f วินาที",model.period))).monospacedDigit().foregroundStyle(.secondary)}
                        Slider(value:$model.period,in:3...10).tint(.primary).accessibilityLabel(model.t("Breathing cycle seconds", th:"จำนวนวินาทีต่อรอบหายใจ"))
                        HStack {Text(model.t("Faster", th:"เร็วขึ้น"));Spacer();Text(model.t("Slower", th:"ช้าลง"))}.font(.system(size:10)).foregroundStyle(.secondary)
                    } else if model.mode == .music {
                        MusicResponseControls(model: model)
                        HStack {Text(model.t("Beat intensity","節拍強度","ความแรงตามจังหวะ")).fontWeight(.medium);Spacer();Image(systemName:"waveform")}
                        Slider(value:$model.musicIntensityPosition,in:0...1).tint(.primary).accessibilityLabel(model.t("Music intensity", th:"ความแรงตามเพลง"))
                        Toggle(model.t("Dark between beats","節拍之間熄滅","ดับระหว่างจังหวะ"),isOn:$model.strobe).toggleStyle(.switch).controlSize(.small)
                        MusicCaptureStatus(model: model)
                    } else if model.mode == .battery {
                        Label("\(Effects.percent(model.battery))% · \(model.display(model.batteryPowerLabel))", systemImage: model.charging ? "bolt.battery" : "battery.75percent").font(.system(size: 14, weight: .medium))
                        BatterySettingsControls(model: model)
                    } else if model.mode == .agents {
                        Label(model.agents.isEmpty ? model.t("Waiting for an agent", th:"รอเอเจนต์") : model.t("\(model.agents.count) sessions · \(model.agentState.rawValue)", th:"\(model.agents.count) เซสชัน · \(model.display(model.agentState.rawValue))"),systemImage:"terminal").font(.system(size:13,weight:.medium))
                        Text(model.t("A soft glow while idle. A pulse while working. Two blinks when an agent needs you and you're away.", th:"เรืองแสงอ่อนๆ ตอนว่าง สว่าง-หรี่ตอนกำลังทำงาน และกะพริบสองครั้งเมื่อเอเจนต์ต้องการคุณขณะที่คุณไม่อยู่หน้าเครื่อง")).font(.system(size:12)).foregroundStyle(.secondary)
                        Button(model.t("Manage Connections", th:"จัดการการเชื่อมต่อ")){model.selectedPage="connections"}
                    } else if model.mode == .typing {
                        Label(model.t("Light up while typing", th:"สว่างขึ้นขณะพิมพ์"), systemImage: "keyboard").font(.system(size: 13, weight: .medium))
                        TypingResponseControls(model: model)
                        Text(model.t("The light turns off shortly after typing stops. With the lid closed, use an external keyboard.", th:"ไฟจะดับหลังหยุดพิมพ์ครู่หนึ่ง ถ้าพับจออยู่ให้ใช้คีย์บอร์ดภายนอก")).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if model.mode == .touch {
                        Label(model.display(model.touchStatus),systemImage:"hand.tap").font(.system(size:12,weight:.medium))
                        if model.touchSource != .screen {Toggle(model.t("Blink on trackpad click", th:"กะพริบเมื่อคลิกแทร็คแพด"),isOn:$model.touchClickBlink).toggleStyle(.switch).controlSize(.small)}
                        TypingResponseControls(model: model)
                        Text(model.t("Works with any app open. Rest a finger to light the logo; lift all fingers to turn it off.", th:"ใช้ได้ไม่ว่าจะเปิดแอปไหนอยู่ วางนิ้วบนแทร็คแพดเพื่อให้โลโก้สว่าง และยกนิ้วออกทั้งหมดเพื่อปิด")).font(.system(size:11)).foregroundStyle(.secondary)
                        Text(model.t("Global trackpad · event-driven, no input polling", th:"แทร็คแพดทั้งระบบ · ทำงานเมื่อมีการสัมผัส ไม่คอยอ่านอินพุตตลอดเวลา")).font(.system(size:10)).foregroundStyle(.tertiary)
                    } else {
                        Label(model.t("Steady brightness","簡單、優雅地亮著。","สว่างคงที่"),systemImage:"circle.fill").font(.system(size:13,weight:.medium))
                        Text(model.t("Uses the brightness set above.","以你選擇的亮度持續發光。","ใช้ความสว่างที่ตั้งไว้ด้านบน")).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                }.font(.system(size:12))
            }.frame(maxWidth:.infinity)
        }
    }
    func modeRow(_ mode: GlowMode) -> some View {
        let selected = model.mode == mode
        let subtitles: [GlowMode:String] = [.steady:model.t("Constant brightness","持續而柔和的光","ความสว่างไม่เปลี่ยน"),.breathe:model.t("Fade in and out","跟隨你的呼吸節奏","ค่อยๆ สว่างแล้วหรี่ลงสลับกัน"),.battery:model.t("Follow battery charge","一眼掌握電量","สว่างตามระดับแบตเตอรี่"),.music:model.t("Respond to system playback","隨音樂律動","เต้นตามเสียงที่เล่นบนเครื่อง"),.agents:model.t("Coding agent status","工作需要你時提醒","บอกสถานะ AI ช่วยเขียนโค้ด"),.touch:model.t("Trackpad and optional typing response","觸控板與選用打字回應","ติดเมื่อแตะแทร็คแพด และเลือกให้ตอบสนองการพิมพ์ได้"),.typing:model.t("Light up while typing","打字時亮起","สว่างขึ้นขณะพิมพ์")]
        return Button {model.mode=mode} label: {
            HStack(spacing:12) {
                Image(systemName:mode.symbol).font(.system(size:17,weight:.medium)).frame(width:34,height:34).foregroundStyle(selected ? Color(nsColor:.windowBackgroundColor) : Color.primary.opacity(0.6)).background(selected ? Color.primary : Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
                VStack(alignment:.leading,spacing:3){Text(model.display(mode.title)).font(.system(size:12,weight:.semibold));Text(subtitles[mode]!).font(.system(size:10)).foregroundStyle(.secondary)}
                Spacer();if selected {Image(systemName:"checkmark").font(.system(size:11,weight:.bold))}
            }.frame(maxWidth:.infinity,alignment:.leading).padding(6)
                .contentShape(Rectangle())
                .background(selected ? Color.primary.opacity(0.045) : .clear,in:RoundedRectangle(cornerRadius:12))
        }.buttonStyle(.plain).accessibilityLabel(model.t("\(mode.title) mode", th:"โหมด\(model.display(mode.title))")).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ConnectionsPage: View {
    @ObservedObject var model: AppModel
    @State private var showHomeSetup=false
    var body: some View {
        PageHeading(eyebrow:"BACKLIT",title:model.t("Connections","連接","การเชื่อมต่อ"),subtitle:model.t("Optional connections for agents and automation.","代理程式和自動化的選用連接。","เชื่อมต่อกับเอเจนต์และระบบอัตโนมัติ (ไม่บังคับ)"))
        AutomationConnections(model: model)
        MCPConnections(model: model)
        Surface(model.t("Coding companions","程式夥伴","ผู้ช่วยเขียนโค้ด")) {
            ForEach(CodingAgent.allCases) { agent in
                let connected = !model.demo && AgentBridge.connected(agent)
                HStack(spacing:14) {
                    Image(systemName:agent == .codex ? "sparkle" : "terminal").font(.system(size:20)).frame(width:42,height:42).background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
                    VStack(alignment:.leading,spacing:4){Text(agent.title).font(.system(size:14,weight:.semibold)); Text(connected ? (agent == .codex ? model.t("Hooks installed · trust them in Codex", th:"ติดตั้ง hooks แล้ว · กดเชื่อถือใน Codex") : model.t("Hooks installed · new sessions are ready", th:"ติดตั้ง hooks แล้ว · เซสชันใหม่พร้อมใช้")) : model.t("Working, waiting, or needs your attention", th:"บอกว่ากำลังทำงาน รออยู่ หรือต้องการให้คุณดู")).font(.system(size:11)).foregroundStyle(.secondary)}
                    Spacer()
                    Button {model.chooseFolder(agent)} label:{Image(systemName:"folder")}.help(model.t("Choose a custom configuration folder", th:"เลือกโฟลเดอร์ตั้งค่าเอง"))
                    Button(connected ? model.t("Disconnect","中斷連接","ยกเลิกการเชื่อมต่อ") : model.t("Connect","連接","เชื่อมต่อ")){model.connectAgent(agent,!connected)}
                }
                if agent == .claude {Divider().padding(.vertical,5)}
            }
            Text(model.t("Hooks send only a session identifier and a status. Your prompts, code, and tool output never enter Backlit.", th:"hooks ส่งแค่รหัสเซสชันและสถานะเท่านั้น พรอมต์ โค้ด และผลลัพธ์จากเครื่องมือของคุณจะไม่ถูกส่งเข้า Backlit")).font(.system(size:11)).foregroundStyle(.secondary)
        }
        Surface {
            HStack(spacing:14) {
                Image(systemName:"house").font(.system(size:20)).frame(width:42,height:42)
                VStack(alignment:.leading,spacing:4){Text("Home Assistant").font(.system(size:14,weight:.semibold));Text(model.t("Optional local light integration", th:"ควบคุมไฟผ่านเครือข่ายภายใน (ไม่บังคับ)")).font(.system(size:11)).foregroundStyle(.secondary)}
                Spacer();Toggle(model.t("Enable Home Assistant bridge", th:"เปิดการเชื่อมต่อ Home Assistant"),isOn:Binding(get:{model.bridgeEnabled},set:{model.configureBridge(enabled:$0,lan:model.bridgeLAN)})).toggleStyle(.switch).labelsHidden()
            }
            DisclosureGroup(model.t("Setup", th:"ตั้งค่า"),isExpanded:$showHomeSetup) {
                VStack(alignment:.leading,spacing:12) {
                    Toggle(model.t("Allow connections from your local network","允許本地網路連接","อนุญาตการเชื่อมต่อจากเครือข่ายภายใน"),isOn:Binding(get:{model.bridgeLAN},set:{model.configureBridge(enabled:model.bridgeEnabled,lan:$0)})).toggleStyle(.switch).controlSize(.small)
                    Text(model.bridgeEnabled ? model.display(model.bridgeStatus) + model.t(" · port 48261", th:" · พอร์ต 48261") : model.t("Off by default. Enable network access for Home Assistant on another device.", th:"ปิดไว้เป็นค่าเริ่มต้น เปิดเมื่อต้องการให้ Home Assistant บนอุปกรณ์อื่นเชื่อมต่อผ่านเครือข่าย")).font(.system(size:11)).foregroundStyle(.secondary)
                    HStack {
                        Button(model.t("Copy Pairing Key", th:"คัดลอกรหัสจับคู่")){model.copyPairingKey()}.disabled(!model.bridgeEnabled)
                        Button(model.t("New Pairing Key", th:"สร้างรหัสจับคู่ใหม่")){model.regeneratePairingKey()}.disabled(model.demo)
                            .help(model.t("Replace the pairing key if it may have been seen by someone else", th:"สร้างรหัสใหม่แทน หากรหัสเดิมอาจหลุดไปถึงคนอื่น"))
                        Button(model.t("Integration Folder", th:"เปิดโฟลเดอร์ integration")) {if let folder=Bundle.main.resourceURL?.appendingPathComponent("HomeAssistant"){NSWorkspace.shared.open(folder)}}
                        Spacer();Link(model.t("Setup guide", th:"คู่มือการตั้งค่า"),destination:URL(string:"https://github.com/t0nyz0/Backlit/blob/main/docs/HOME-ASSISTANT.md")!)
                    }.font(.system(size:11))
                }.padding(.top,10)
            }.font(.system(size:12))
        }

    }
    func useCase(_ symbol: String,_ title: String,_ detail: String) -> some View { VStack(alignment:.leading,spacing:9){Image(systemName:symbol).font(.system(size:20,weight:.light));Text(title).font(.system(size:12,weight:.semibold));Text(detail).font(.system(size:11)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,alignment:.leading) }
}

struct SettingsPage: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text(model.t("Settings","設定","การตั้งค่า")).font(.system(size:31,weight:.semibold))
        Surface(model.t("General","融入你的 Mac","ทั่วไป")) {
            settingRow(model.t("Appearance", th:"ลักษณะที่ปรากฏ"),model.t("Follow your Mac, or choose a look.", th:"ตามการตั้งค่าของ Mac หรือเลือกเอง")) {Picker(model.t("Appearance", th:"ลักษณะที่ปรากฏ"),selection:$model.appearance){Text(model.t("System", th:"ตามระบบ")).tag("system");Text(model.t("Light", th:"สว่าง")).tag("light");Text(model.t("Dark", th:"มืด")).tag("dark")}.labelsHidden().frame(width:150)}
            Divider()
            settingRow(model.t("Language", th:"ภาษา"),"English / 繁體中文 / ไทย") {Picker(model.t("Language", th:"ภาษา"),selection:$model.language){Text("English").tag("en");Text("繁體中文").tag("zh-Hant");Text("ไทย").tag("th")}.labelsHidden().frame(width:150)}
            Divider()
            settingRow(model.t("Show menu bar icon", th:"แสดงไอคอนในแถบเมนู"), model.t("When hidden, reopen Backlit from the Dock or Applications. Settings stays available from the app menu.", th:"ถ้าซ่อนไว้ เปิด Backlit ได้จาก Dock หรือโฟลเดอร์ Applications และยังเปิดการตั้งค่าได้จากเมนูของแอป")) {
                Toggle(model.t("Show menu bar icon", th:"แสดงไอคอนในแถบเมนู"), isOn: $model.menuBarIconVisible).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            settingRow(model.t("Open at login","登入時開啟","เปิดเมื่อเข้าสู่ระบบ"),model.t("Keep Backlit a click away in the menu bar.", th:"ให้ Backlit อยู่ในแถบเมนู พร้อมใช้ได้ในคลิกเดียว")) {Toggle(model.t("Open at login", th:"เปิดเมื่อเข้าสู่ระบบ"),isOn:Binding(get:{model.loginEnabled},set:{model.setLogin($0)})).labelsHidden().toggleStyle(.switch)}
            Divider()
            LogoShortcutControls(model:model)
        }
        Surface(model.t("Logo and power","進階控制","โลโก้และพลังงาน")) {
            settingRow(model.t("Keep logo on with lid closed","闔上螢幕時保持發光","เปิดไฟโลโก้ค้างไว้ขณะพับจอ"),model.t("Keeps this Mac awake and may leave its built-in screen lit while closed. Limited to 30 minutes; also stops for low battery, heat or Low Power Mode. Keep it on a hard, ventilated surface, never in a bag.","闔蓋時 Mac 保持喚醒，內建螢幕可能仍亮著。最長 30 分鐘；電量不足、過熱或開啟低耗電模式時也會停止。請放在通風的硬質平面上，切勿放入袋中。","Mac จะไม่พักเครื่อง และจอในตัวอาจยังสว่างอยู่ขณะพับ ทำงานได้นานสุด 30 นาที และหยุดเองเมื่อแบตเตอรี่ต่ำ เครื่องร้อน หรือเปิดโหมดพลังงานต่ำ ควรวางเครื่องบนพื้นแข็งที่ระบายอากาศได้ดี ห้ามใส่ไว้ในกระเป๋า")) {Toggle(model.t("Keep logo on with lid closed", th:"เปิดไฟโลโก้ค้างไว้ขณะพับจอ"),isOn:Binding(get:{model.lidRequested},set:{model.setLid($0)})).labelsHidden().toggleStyle(.switch)}
            Text(model.display(model.lidPreferenceStatus)).font(.system(size: 11)).foregroundStyle(.secondary)
            LidDurationControls(model: model)
            Divider()
            settingRow(model.t("Override ambient brightness limit","任何環境下的全亮度","ปลดขีดจำกัดความสว่างตามแสงรอบตัว"),model.t("Optional ambient-light override. macOS asks for administrator approval. Your previous limits are saved.", th:"ไม่บังคับ: ปลดขีดจำกัดที่ macOS ลดความสว่างตามแสงรอบตัว ต้องยืนยันด้วยรหัสผู้ดูแลระบบ และค่าเดิมจะถูกบันทึกไว้")) {Toggle(model.t("Override ambient brightness limit", th:"ปลดขีดจำกัดความสว่างตามแสงรอบตัว"),isOn:Binding(get:{model.ambientUnlocked},set:{model.setAmbient($0)})).labelsHidden().toggleStyle(.switch)}
            if !model.demo && (model.needsLightRecovery || model.savedLidPauseNeedsReview) && (!model.controlWanted || !model.controlling) {
                Divider()
                settingRow(model.t("Restore your light","還原你的燈光","กู้คืนไฟของคุณ"), model.savedLidRecoveryUnconfirmed
                    ? model.t("Request restoration. Native handback remains unconfirmed; your saved closed-lid choice stays paused.", th:"ส่งคำขอกู้คืน (ยังยืนยันไม่ได้ว่าระบบรับการควบคุมกลับไปแล้ว) การตั้งค่าขณะพับจอที่บันทึกไว้จะยังหยุดชั่วคราวอยู่")
                    : model.t("Finish recovering the previous session and reconnect.", th:"กู้คืนเซสชันก่อนหน้าให้เสร็จ แล้วเชื่อมต่อใหม่")) {Button(model.t("Restore Light","還原燈光","กู้คืนไฟ")){model.repairAndResume()}}
            }
        }
        Surface {
            HStack(spacing:14) {BrandGlyph(size:52);VStack(alignment:.leading,spacing:4){Text("Backlit").font(.system(size:18,weight:.semibold));Text(model.t("Version", th:"เวอร์ชัน") + " \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development") · t0nyz").font(.system(size:11)).foregroundStyle(.secondary)};Spacer();UpdateControls(updater: model.updater, preview: model.demo, display: { model.display($0) })}
            Divider()
            HStack {Link("GitHub ↗",destination:URL(string:"https://github.com/t0nyz0/Backlit")!);Text("·").foregroundStyle(.tertiary);Link("t0nyz.com ↗",destination:URL(string:"https://t0nyz.com")!);Spacer();Link(model.t("☕ Buy me a coffee", th:"☕ เลี้ยงกาแฟผู้พัฒนา"),destination:URL(string:"https://buymeacoffee.com/tonyz")!)}.font(.system(size:12))
        }
        Text(model.t("The logo hardware produces white light. Backlit changes its brightness and rhythm, never the screen brightness. ", th:"ฮาร์ดแวร์โลโก้ให้แสงสีขาวเท่านั้น Backlit ปรับแค่ความสว่างและจังหวะของไฟ ไม่ยุ่งกับความสว่างหน้าจอ")).font(.system(size:11)).foregroundStyle(.secondary)
    }
    func settingRow<Accessory:View>(_ title: String,_ subtitle: String,@ViewBuilder accessory:()->Accessory) -> some View {
        HStack(spacing:22){VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:13,weight:.medium));Text(subtitle).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)};Spacer(minLength:20);accessory()}
    }
}

struct LidDurationControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.t("Closed-lid duration","闔蓋持續時間","ระยะเวลาขณะพับจอ")).fontWeight(.medium)
            HStack(spacing: 8) {
                Text(model.t("Keep on for","保持開啟","เปิดค้างไว้นาน"))
                Spacer()
                TextField(model.t("Duration","持續時間","ระยะเวลา"), value: Binding(
                    get: { model.lidSessionDuration.amount }, set: { model.setLidDuration(amount: $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 65)
                    .accessibilityLabel(model.t("Closed-lid duration amount","闔蓋持續時間數值","จำนวนนาทีขณะพับจอ"))
                Stepper(model.t("Duration","持續時間","ระยะเวลา"), value: Binding(
                    get: { model.lidSessionDuration.amount }, set: { model.setLidDuration(amount: $0) }), in: 1...30).labelsHidden()
                Text(model.t("minutes","分鐘","นาที"))
            }
            Text(model.t("Maximum 30 minutes per closure. Sleep counts toward the timer; relaunching does not reset it. This limit does not guarantee safe temperatures.","每次闔蓋最長 30 分鐘。睡眠時間也會計入，重新開啟 App 不會重設計時器。此限制並不保證溫度安全。","พับจอแต่ละครั้งได้นานสุด 30 นาที เวลาที่เครื่องพักนับรวมด้วย และการเปิดแอปใหม่ไม่ทำให้เริ่มนับใหม่ ขีดจำกัดนี้ไม่ได้รับประกันว่าอุณหภูมิจะปลอดภัย"))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .disabled(!model.canEditLidDuration)
        if !model.canEditLidDuration {
            Text(model.t("Turn off the closed-lid session and let cleanup finish before changing its duration.","請先關閉闔蓋功能並等待還原完成，再更改持續時間。","ปิดการทำงานขณะพับจอและรอให้เคลียร์เสร็จก่อน จึงจะเปลี่ยนระยะเวลาได้"))
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
    func updateNSView(_ view:KeyView,context:Context){if view.prompt != prompt {view.prompt=prompt;view.needsDisplay=true};view.capture=capture;view.invalid=invalid;view.cancel=cancel}
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
        override func draw(_ dirtyRect:NSRect){(prompt as NSString).draw(at:NSPoint(x:70,y:24),withAttributes:[.font:NSFont.systemFont(ofSize:15),.foregroundColor:NSColor.secondaryLabelColor])}
    }
}

/// Small instrument-style lid preview; the menu remains a compact control strip.
struct MenuLidPreview: View {
    @ObservedObject var presentation:LightPresentation
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius:8).fill(LinearGradient(colors:[Color(white:0.30),Color(white:0.13)],startPoint:.topLeading,endPoint:.bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.25),lineWidth:0.6))
            MenuLightMark(level: presentation.level)
            VStack {Spacer();Capsule().fill(.white.opacity(0.22)).frame(height:1).padding(.horizontal,14).padding(.bottom,4)}
        }.frame(width:88,height:60).accessibilityLabel("Logo preview, \(Effects.percent(presentation.level)) percent")
    }
}

struct MenuView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(spacing:10) {
                BrandGlyph(size:30)
                VStack(alignment:.leading,spacing:2) { Text("Backlit").font(.system(size:16,weight:.semibold));Text(model.t("MacBook PROLED Logo Control","MacBook 標誌控制","ควบคุมไฟโลโก้ MacBook PROLED")).font(.system(size:10)).foregroundStyle(.secondary) }
                Spacer()
                Button {model.openWindow?()} label:{Image(systemName:"arrow.up.right.square").font(.system(size:15))}.buttonStyle(.plain).help(model.t("Open workspace", th:"เปิดหน้าต่างหลัก"))
            }
            Divider()
            HStack(spacing:12) {
                MenuLidPreview(presentation:model.presentation)
                VStack(alignment:.leading,spacing:4) {Text(model.t("Backlight","背光","ไฟโลโก้")).font(.system(size:13,weight:.semibold));Text(model.display(model.status)).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal:false,vertical:true)}
                Spacer();Toggle(model.t("Backlight", th:"ไฟโลโก้"),isOn:$model.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Text(model.t("Behavior","模式","รูปแบบไฟ")).font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                Picker(model.t("Behavior", th:"รูปแบบไฟ"),selection:$model.mode) {ForEach(model.availableModes){mode in Label(model.display(mode.title),systemImage:mode.symbol).tag(mode)}}.labelsHidden().pickerStyle(.menu).frame(width:150)
            }
            if model.mode == .battery {
                Text(model.t("Battery-driven output", th:"ความสว่างตามแบตเตอรี่")).font(.system(size: 12, weight: .medium))
                BatteryOutputReadout(model: model, compact: true)
            } else {
            VStack(spacing:10) {
                HStack {Text(model.t("Brightness","亮度","ความสว่าง")).font(.system(size:12,weight:.medium));Spacer();Text("\(Effects.percent(model.brightness))%").font(.system(size:12)).monospacedDigit().foregroundStyle(.secondary)}
                HStack(spacing:10) {Image(systemName:"sun.min");Slider(value:$model.brightness,in:0...1).tint(.primary).accessibilityLabel(model.t("Logo brightness", th:"ความสว่างโลโก้"));Image(systemName:"sun.max")}.font(.system(size:12)).foregroundStyle(.secondary)
            }
            }
            if model.mode == .breathe {
                VStack(spacing:8) {HStack {Text(model.t("Breathing pace","呼吸速度","ความเร็วจังหวะหายใจ"));Spacer();Text(model.t(String(format:"%.1f seconds",model.period), th:String(format:"%.1f วินาที",model.period))).monospacedDigit().foregroundStyle(.secondary)}.font(.system(size:11));Slider(value:$model.period,in:3...10).tint(.primary).accessibilityLabel(model.t("Breathing cycle seconds", th:"จำนวนวินาทีต่อรอบหายใจ"))}
            } else if model.mode == .music {
                MusicResponseControls(model: model).font(.system(size:11))
                VStack(spacing:8) {HStack{Text(model.t("Beat intensity", th:"ความแรงตามจังหวะ"));Slider(value:$model.musicIntensityPosition,in:0...1).tint(.primary).accessibilityLabel(model.t("Music intensity", th:"ความแรงตามเพลง"))};Toggle(model.t("Dark between beats", th:"ดับระหว่างจังหวะ"),isOn:$model.strobe).toggleStyle(.switch).controlSize(.small);MusicCaptureStatus(model: model)}.font(.system(size:11))
            } else if model.mode == .battery {
                Label("\(Effects.percent(model.battery))% · \(model.display(model.batteryPowerLabel))",systemImage:"battery.75percent").font(.system(size:11)).foregroundStyle(.secondary)
            } else if model.mode == .typing {
                TypingResponseControls(model: model).font(.system(size: 11))
            } else if model.mode == .touch {
                TypingResponseControls(model: model).font(.system(size:11))
                VStack(alignment:.leading,spacing:8) {if model.touchSource != .screen {Toggle(model.t("Blink on click", th:"กะพริบเมื่อคลิก"),isOn:$model.touchClickBlink).toggleStyle(.switch).controlSize(.small)};Label(model.display(model.touchStatus),systemImage:"hand.tap").font(.system(size:11)).foregroundStyle(.secondary)}
            } else if model.mode == .agents {
                Label(model.agents.isEmpty ? model.t("Waiting for an agent", th:"รอเอเจนต์") : model.display(model.agentState.rawValue.capitalized),systemImage:"terminal").font(.system(size:11)).foregroundStyle(.secondary)
            }
            if !model.demo && model.needsLightRecovery && (!model.controlWanted || !model.controlling) {
                Button(model.t("Restore Light","還原燈光","กู้คืนไฟ")){model.repairAndResume()}.buttonStyle(.borderedProminent).tint(.primary)
            }
            Divider()
            HStack {
                Button {model.selectedPage="settings";model.openWindow?()} label:{Label(model.t("Settings","設定","การตั้งค่า"),systemImage:"gearshape")}.buttonStyle(.plain)
                Spacer();Text(model.shortcutLabel).font(.system(size:10)).foregroundStyle(.tertiary)
                Button(model.t("Quit", th:"ออก")){model.quit()}.buttonStyle(.plain).padding(.leading,10)
            }.font(.system(size:11))
        }.padding(20).frame(width:320).background(Color(nsColor:.windowBackgroundColor)).preferredColorScheme(model.colorScheme)
    }
}
