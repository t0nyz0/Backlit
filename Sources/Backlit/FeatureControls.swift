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

struct AutomationConnections: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Surface("Other apps") {
            Toggle("Allow Backlit links and other apps", isOn: $model.automationsEnabled).toggleStyle(.switch)
            Text("Allows Backlit links to change the light. Native Shortcuts actions are unavailable in this build.").font(.system(size: 11)).foregroundStyle(.secondary)
            if model.automationsEnabled {
                HStack {
                    Text("Stream Deck").fontWeight(.medium)
                    Spacer()
                    Button("Copy Toggle Link") { model.copyToggleLink() }
                }

            }
        }.font(.system(size: 12))
    }
}
