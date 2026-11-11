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

struct MusicCaptureStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.demo {
                Text("Preview uses a sample waveform.")
            } else if model.audioStarting {
                Text("Connecting to system audio…")
            } else if model.audioStopping {
                if let error = model.audioCaptureError { Text(error) }
                Text("Waiting for macOS to finish the system audio request and cleanup.")
                Text("You can switch modes or quit Backlit. Retry becomes available after cleanup finishes.")
                if model.audioPermissionHelp {
                    Button("Retry System Audio") { model.startAudio() }.disabled(true)
                }
            } else if model.audioPermissionHelp {
                Text(model.audioCaptureError ?? "System audio is unavailable.")
                Text("If access is off, allow Backlit in Privacy & Security → Screen & System Audio Recording.")
                HStack {
                    Button("Retry System Audio") { model.startAudio() }.disabled(!model.enabled || model.pausedReason != nil)
                    Button("Open Privacy Settings") { model.openAudioPrivacy() }
                }
            } else {
                Text(model.audioRunning ? "System audio follows Music mode." : "System audio starts with Music when your light is on and your Mac is active.")
            }
            Text("Playback only. No microphone. Nothing recorded.")
        }.font(.system(size: 10)).foregroundStyle(.secondary)
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
