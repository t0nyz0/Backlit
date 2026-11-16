import SwiftUI
import AppKit

struct LogoShortcutControls: View {
    @ObservedObject var model: AppModel
    @State private var recording: LogoShortcutAction?
    @State private var captureIssue: String?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ForEach(LogoShortcutAction.allCases) { action in
                HStack {
                    Text(model.display(action.title))
                    Spacer()
                    Button(model.logoShortcuts[action]?.label ?? model.t("Off", th:"ปิด")) {
                        captureIssue = nil; model.setShortcutRecording(true); recording = action
                    }.frame(minWidth:95).accessibilityLabel(model.t("Change " + action.title.lowercased() + " shortcut", th:"เปลี่ยนคีย์ลัด" + model.display(action.title)))
                    Button(model.t("Reset", th:"รีเซ็ต")) { _ = model.setLogoShortcut(action.defaultBinding,action:action) }
                    Button(model.t("Disable", th:"ปิดใช้")) { _ = model.setLogoShortcut(nil,action:action) }
                        .disabled(model.logoShortcuts[action] == nil)
                }
                if let issue = model.shortcutIssues[action] {
                    Text(model.display(issue)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Text(model.t("Brightness shortcuts change the manual level by 5%. They keep the current behavior and on/off state. Battery brightness stays automatic.", th:"คีย์ลัดปรับความสว่างทีละ 5% โดยไม่เปลี่ยนรูปแบบไฟหรือสถานะเปิด/ปิด ส่วนโหมดแบตเตอรี่ยังปรับความสว่างเองอัตโนมัติ"))
                .font(.system(size:11)).foregroundStyle(.secondary)
            Divider()
            Toggle(model.t("Shift + hardware brightness keys (experimental)", th:"ใช้ Shift + ปุ่มความสว่างบนคีย์บอร์ด (ทดลอง)"),isOn:Binding(
                get:{model.shiftBrightnessEnabled},set:{model.configureShiftBrightness($0,prompt:true)})).toggleStyle(.switch)
            Text(model.t("Off by default. Requires Accessibility and Input Monitoring. Keyboard support varies: verify that the screen does not also change. Regular shortcuts work without these permissions.", th:"ปิดไว้เป็นค่าเริ่มต้น ต้องอนุญาต Accessibility และ Input Monitoring คีย์บอร์ดแต่ละรุ่นอาจทำงานต่างกัน ให้ตรวจดูว่าความสว่างหน้าจอไม่เปลี่ยนตามไปด้วย ส่วนคีย์ลัดปกติใช้ได้โดยไม่ต้องขอสิทธิ์เหล่านี้"))
                .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(model.display(model.shiftBrightnessStatus)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Link(model.t("Open Accessibility", th:"เปิด Accessibility"),destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                Link(model.t("Open Input Monitoring", th:"เปิด Input Monitoring"),destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }.font(.system(size:11))
        }.font(.system(size:12))
        .sheet(item:$recording,onDismiss:{model.setShortcutRecording(false)}) { action in
            VStack(spacing:18) {
                Text(model.display(action.title)).font(.title2)
                Text(model.t("Press Command, Control or Option with a regular key. Escape cancels.", th:"กด Command, Control หรือ Option พร้อมปุ่มทั่วไป กด Esc เพื่อยกเลิก")).foregroundStyle(.secondary)
                ShortcutRecorder(prompt:model.t("Waiting for keys…", th:"รอการกดปุ่ม…"),capture:{binding in
                    if model.setLogoShortcut(binding,action:action) { recording = nil }
                    else { captureIssue = model.shortcutIssues[action] }
                },invalid:{captureIssue = $0},cancel:{recording = nil}).frame(width:380,height:70)
                if let captureIssue { Text(model.display(captureIssue)).font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:440) }
                Button(model.t("Cancel", th:"ยกเลิก")) { recording = nil }
            }.padding(32)
        }
        .onDisappear { model.setShortcutRecording(false) }
    }
}
