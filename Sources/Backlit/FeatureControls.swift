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
            if model.mode != .typing {
                Toggle("Also respond to typing", isOn: Binding(get: { model.typingEnabled }, set: { model.setTypingEnabled($0) })).toggleStyle(.switch).controlSize(.small)
            }
            if model.mode == .typing || model.typingEnabled {
                Text(model.typingStatus).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Enable or retry typing access") { model.retryTypingAccess() }
                Link("Open Input Monitoring", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                if let feedback = model.typingAccessFeedback {
                    Text("Last access check: " + feedback).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if model.typingAccessCheck?.after == false {
                        Text("If Backlit is already enabled there but access is still denied after an update, remove the old Backlit entry, add the installed Backlit app again, enable it, then reopen Backlit.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Requires Input Monitoring. Uses timing only; no characters are read or saved. Secure Input can pause this response.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

/// Native settings layout scoped to Connections, leaving other pages unchanged.
struct ConnectionSettingsSection<Content: View>: View {
    let title: String
    let detail: String
    let caption: String
    let content: Content
    init(_ title: String, detail: String, caption: String = "", @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.caption = caption; self.content = content()
    }
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 17, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !caption.isEmpty {
                    Text(caption).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(width: 174, alignment: .leading).padding(.top, 8)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConnectionSettingsGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct MCPConnections: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ConnectionSettingsSection("MCP control",
            detail: "On-demand access for an assistant to check or change your light when you ask.",
            caption: "Model Context Protocol · Off by default") {
            VStack(alignment: .leading, spacing: 10) {
                ConnectionSettingsGroup {
                    HStack(spacing: 12) {
                        rowLabel("MCP access")
                        Picker("MCP access", selection: Binding(get: { model.mcpAccess }, set: { model.configureMCPAccess($0) })) {
                            ForEach(MCPAccess.allCases) { access in Text(access.title).tag(access) }
                        }.labelsHidden().frame(width: 205)
                        Spacer(minLength: 0)
                    }.padding(.vertical, 14)
                    if model.mcpAccess != .off {
                        Divider()
                        HStack(spacing: 12) {
                            rowLabel("Assistant setup")
                            HStack(spacing: 8) {
                                Button("Copy Codex Setup") { model.copyMCPSetup(claude: false) }
                                Button("Copy Claude Code Setup") { model.copyMCPSetup(claude: true) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 14)
                        Divider()
                        HStack(spacing: 12) {
                            rowLabel("Access key")
                            Spacer(minLength: 0)
                            Button("Replace AI Key") { model.regenerateMCPKey() }
                        }.padding(.vertical, 14)
                    }
                }.font(.system(size: 12)).controlSize(.regular)
                if model.mcpAccess != .off {
                    Text("Your assistant may send light status to its model provider. Music and Typing need access enabled in Backlit first. Status hooks stay separate.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 6)
                }
            }
        }.accessibilityIdentifier("mcp-control-section")
    }
    private func rowLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).frame(width: 95, alignment: .leading)
    }
}
