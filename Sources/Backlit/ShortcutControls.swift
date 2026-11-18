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
                    Text(model.l(action.title)).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    Button(model.logoShortcuts[action]?.label ?? model.l("Off")) {
                        captureIssue = nil; model.setShortcutRecording(true); recording = action
                    }.frame(minWidth:95).accessibilityLabel(model.l(action.title)).accessibilityHint(model.l("Press Command, Control or Option with a regular key. Escape cancels."))
                    Button(model.l("Reset")) { _ = model.setLogoShortcut(action.defaultBinding,action:action) }
                    Button(model.l("Disable")) { _ = model.setLogoShortcut(nil,action:action) }
                        .disabled(model.logoShortcuts[action] == nil)
                }
                if let issue = model.shortcutIssues[action] {
                    Text(model.l(issue)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }
            Text(model.l("Brightness shortcuts change the manual level by 5%. They keep the current behavior and on/off state. Battery brightness stays automatic."))
                .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Divider()
            Toggle(model.l("Shift + hardware brightness keys (experimental)"),isOn:Binding(
                get:{model.shiftBrightnessEnabled},set:{model.configureShiftBrightness($0,prompt:true)})).toggleStyle(.switch)
            Text(model.l("Off by default. Requires Accessibility and Input Monitoring. Keyboard support varies: verify that the screen does not also change. Regular shortcuts work without these permissions."))
                .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text(model.l(model.shiftBrightnessStatus)).font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Link(model.l("Open Accessibility"),destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                Link(model.l("Open Input Monitoring"),destination:URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }.font(.system(size:11))
        }.font(.system(size:12))
        .sheet(item:$recording,onDismiss:{model.setShortcutRecording(false)}) { action in
            VStack(spacing:18) {
                Text(model.l(action.title)).font(.title2)
                Text(model.l("Press Command, Control or Option with a regular key. Escape cancels.")).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).frame(maxWidth:440)
                ShortcutRecorder(prompt:model.l("Waiting for keys…"),capture:{binding in
                    if model.setLogoShortcut(binding,action:action) { recording = nil }
                    else { captureIssue = model.shortcutIssues[action] }
                },invalid:{captureIssue = $0},cancel:{recording = nil}).frame(width:380,height:70)
                if let captureIssue { Text(model.l(captureIssue)).font(.system(size:12)).foregroundStyle(.secondary).frame(maxWidth:440) }
                Button(model.l("Cancel")) { recording = nil }
            }.padding(32)
        }
        .onDisappear { model.setShortcutRecording(false) }
    }
}
