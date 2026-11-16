import SwiftUI

struct MusicResponseControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(model.t("Automatic level", th:"ปรับระดับเสียงอัตโนมัติ"), isOn: $model.musicAutomatic).toggleStyle(.switch).controlSize(.small)
            Picker(model.t("Response", th:"การตอบสนอง"), selection: $model.musicPreset) {
                ForEach(MusicResponsePreset.allCases) { preset in Text(model.display(preset.title)).tag(preset) }
            }
            Text(model.t("Adapts to playback level. Intensity adjusts the result; your brightness sets its ceiling.", th:"ปรับตามระดับเสียงที่เล่นอยู่ ความแรงใช้ปรับผลลัพธ์ ส่วนความสว่างที่ตั้งไว้คือค่าสูงสุด")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct MusicCaptureStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.demo {
                Text(model.t("Preview uses a sample waveform.", th:"โหมดตัวอย่างใช้คลื่นเสียงจำลอง"))
            } else if model.audioStarting {
                Text(model.t("Connecting to system audio…", th:"กำลังเชื่อมต่อเสียงระบบ…"))
            } else if model.audioStopping {
                if let error = model.audioCaptureError { Text(model.display(error)) }
                Text(model.t("Waiting for macOS to finish the system audio request and cleanup.", th:"รอ macOS จัดการคำขอใช้เสียงระบบและเคลียร์ให้เสร็จ"))
                Text(model.t("You can switch modes or quit Backlit. Retry becomes available after cleanup finishes.", th:"ระหว่างนี้เปลี่ยนโหมดหรือออกจาก Backlit ได้ ปุ่มลองใหม่จะใช้ได้เมื่อเคลียร์เสร็จ"))
                if model.audioPermissionHelp {
                    Button(model.t("Retry System Audio", th:"ลองเชื่อมเสียงระบบอีกครั้ง")) { model.startAudio() }.disabled(true)
                }
            } else if model.audioPermissionHelp {
                Text(model.display(model.audioCaptureError ?? "System audio is unavailable."))
                Text(model.t("If access is off, allow Backlit in Privacy & Security → Screen & System Audio Recording.", th:"ถ้ายังไม่ได้อนุญาต ให้เปิดสิทธิ์ Backlit ที่ Privacy & Security → Screen & System Audio Recording"))
                HStack {
                    Button(model.t("Retry System Audio", th:"ลองเชื่อมเสียงระบบอีกครั้ง")) { model.startAudio() }.disabled(!model.enabled || model.pausedReason != nil)
                    Button(model.t("Open Privacy Settings", th:"เปิดการตั้งค่าความเป็นส่วนตัว")) { model.openAudioPrivacy() }
                }
            } else {
                Text(model.audioRunning ? model.t("System audio follows Music mode.", th:"เสียงระบบทำงานตามโหมดเพลง") : model.t("System audio starts with Music when your light is on and your Mac is active.", th:"เสียงระบบจะเริ่มพร้อมโหมดเพลง เมื่อไฟเปิดอยู่และกำลังใช้ Mac"))
            }
            Text(model.t("Playback only. No microphone. Nothing recorded.", th:"ใช้เฉพาะเสียงที่เล่นบนเครื่อง ไม่ใช้ไมโครโฟน และไม่บันทึกอะไรไว้"))
        }.font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

struct TypingResponseControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mode != .typing {
                Toggle(model.t("Also respond to typing", th:"ตอบสนองการพิมพ์ด้วย"), isOn: Binding(get: { model.typingEnabled }, set: { model.setTypingEnabled($0) })).toggleStyle(.switch).controlSize(.small)
            }
            if model.mode == .typing || model.typingEnabled {
                Text(model.display(model.typingStatus)).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(model.t("Enable or retry typing access", th:"ขอสิทธิ์การพิมพ์ หรือลองอีกครั้ง")) { model.retryTypingAccess() }
                Link(model.t("Open Input Monitoring", th:"เปิด Input Monitoring"), destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                if let feedback = model.typingAccessFeedback {
                    Text(model.t("Last access check: ", th:"ผลตรวจสิทธิ์ล่าสุด: ") + feedback).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if model.typingAccessCheck?.after == false {
                        Text(model.t("If Backlit is already enabled there but access is still denied after an update, remove the old Backlit entry, add the installed Backlit app again, enable it, then reopen Backlit.", th:"ถ้าเปิดสิทธิ์ให้ Backlit แล้วแต่หลังอัปเดตยังถูกปฏิเสธ ให้ลบ Backlit ตัวเดิมออกจากรายการ เพิ่มแอป Backlit ที่ติดตั้งไว้เข้าไปใหม่ เปิดสิทธิ์ แล้วเปิด Backlit อีกครั้ง")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(model.t("Requires Input Monitoring. Uses timing only; no characters are read or saved. Secure Input can pause this response.", th:"ต้องอนุญาต Input Monitoring โดยใช้แค่จังหวะการกด ไม่อ่านและไม่บันทึกตัวอักษรที่พิมพ์ และอาจหยุดชั่วคราวเมื่อระบบเปิด Secure Input")).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AutomationConnections: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Surface(model.t("Other apps", th:"แอปอื่นๆ")) {
            Toggle(model.t("Allow Backlit links and other apps", th:"อนุญาตลิงก์ Backlit และแอปอื่น"), isOn: $model.automationsEnabled).toggleStyle(.switch)
            Text(model.t("Allows Backlit links to change the light. Native Shortcuts actions are unavailable in this build.", th:"ให้ลิงก์ Backlit ปรับไฟได้ (บิลด์นี้ยังใช้คำสั่งในแอป Shortcuts ไม่ได้)")).font(.system(size: 11)).foregroundStyle(.secondary)
            if model.automationsEnabled {
                HStack {
                    Text("Stream Deck").fontWeight(.medium)
                    Spacer()
                    Button(model.t("Copy Toggle Link", th:"คัดลอกลิงก์เปิด/ปิด")) { model.copyToggleLink() }
                }

            }
        }.font(.system(size: 12))
    }
}

struct MCPConnections: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Surface(model.t("AI control", th:"ควบคุมด้วย AI")) {
            Picker(model.t("Allow AI connections", th:"อนุญาตการเชื่อมต่อ AI"), selection:Binding(get:{model.mcpAccess},set:{model.configureMCPAccess($0)})) {
                ForEach(MCPAccess.allCases) { access in Text(model.display(access.title)).tag(access) }
            }
            Text(model.t("Connect a local AI assistant to check this light or change it when you ask. Off by default.", th:"ให้ผู้ช่วย AI บนเครื่องนี้ดูสถานะหรือปรับไฟตามที่คุณสั่ง ปิดไว้เป็นค่าเริ่มต้น"))
                .font(.system(size:11)).foregroundStyle(.secondary)
            if model.mcpAccess != .off {
                HStack {
                    Button(model.t("Copy Codex Setup", th:"คัดลอกการตั้งค่า Codex")) { model.copyMCPSetup(claude:false) }
                    Button(model.t("Copy Claude Code Setup", th:"คัดลอกการตั้งค่า Claude Code")) { model.copyMCPSetup(claude:true) }
                    Spacer()
                    Button(model.t("Replace AI Key", th:"เปลี่ยนคีย์ AI")) { model.regenerateMCPKey() }
                }.font(.system(size:11))
                Text(model.t("Your assistant may send light status to its model provider. Music and Typing need access enabled in Backlit first. Status hooks stay separate.", th:"ผู้ช่วยอาจส่งสถานะไฟไปให้ผู้ให้บริการโมเดล โหมดเพลงและการพิมพ์ต้องเปิดสิทธิ์ใน Backlit ก่อน ส่วน status hooks แยกจากการตั้งค่านี้"))
                    .font(.system(size:11)).foregroundStyle(.secondary)
            }
        }.font(.system(size:12))
    }
}
