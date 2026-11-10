import SwiftUI

struct MusicResponseControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Automatic level", isOn: $model.musicAutomatic).toggleStyle(.switch).controlSize(.small)
            Picker("Response", selection: $model.musicPreset) {
                ForEach(MusicResponsePreset.allCases) { preset in Text(preset.title).tag(preset) }
            }
            Text("Adapts to playback level. Intensity adjusts the result; your brightness sets its ceiling.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct TypingResponseControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Also respond to typing", isOn: Binding(get: { model.typingEnabled }, set: { model.setTypingEnabled($0) })).toggleStyle(.switch).controlSize(.small)
            if model.typingEnabled {
                Text(model.typingStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Requires Input Monitoring. Uses timing only; no characters are read or saved. Secure Input can pause this response.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

struct SignalResponseControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.signalStatus, systemImage: "dot.radiowaves.left.and.right")
            Text("Build, export, backup, recording, and streaming signals appear here. Idle stays dark; completed work pulses briefly.").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            Stepper("Focus · \(model.focusMinutes) minutes", value: $model.focusMinutes, in: 1...120)
            HStack {
                Button("Start Focus") { model.startFocus() }
                Spacer()
                Button("Clear Signals") { model.clearSignals() }.disabled(model.signalCount == 0)
            }
        }
    }
}

struct AutomationConnections: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Surface("Other apps") {
            Toggle("Allow Shortcuts and other apps", isOn: $model.automationsEnabled).toggleStyle(.switch)
            Text("Lets Shortcuts and Backlit links change the light. Activity signals use the authenticated local connection below.").font(.system(size: 11)).foregroundStyle(.secondary)
            if model.automationsEnabled {
                HStack {
                    Text("Stream Deck").fontWeight(.medium)
                    Spacer()
                    Button("Copy Toggle Link") { model.copyToggleLink() }
                }
                HStack {
                    Text("OBS Studio").fontWeight(.medium)
                    Spacer()
                    Button("Save OBS Script…") { model.saveOBSScript() }
                }
                Text("Select Signals to display activity. External signals expire unless refreshed; they cannot change files or run commands.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12))
    }
}
