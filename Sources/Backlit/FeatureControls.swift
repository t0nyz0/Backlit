import SwiftUI

struct BatteryResponseControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.batteryAvailable {
                Label("\(Int(model.battery * 100))% · \(model.charging ? "Plugged in" : "On battery")", systemImage: model.charging ? "bolt.battery" : "battery.75percent")
            } else { Text("Battery state unavailable").foregroundStyle(.secondary) }
            Picker("While plugged in", selection: $model.batteryOptions.chargingStyle) {
                ForEach(BatteryChargeStyle.allCases) { style in Text(style.title).tag(style) }
            }
            if model.batteryOptions.chargingStyle == .breathe {
                Text("Breathes while charging, then stays solid at 100%. On battery, brightness follows the charge level.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Toggle("Charge-ready signal", isOn: $model.batteryOptions.readyEnabled).toggleStyle(.switch).controlSize(.small)
            if model.batteryOptions.readyEnabled {
                HStack {
                    Text("Ready at")
                    Slider(value: $model.batteryOptions.readyThreshold, in: 0.5...1, step: 0.01).accessibilityLabel("Charge-ready threshold")
                    Text("\(Int((model.batteryOptions.readyThreshold * 100).rounded()))%").monospacedDigit().frame(width: 35)
                }
                Picker("Signal", selection: $model.batteryOptions.readyStyle) {
                    ForEach(BatteryReadyStyle.allCases) { style in Text(style.title).tag(style) }
                }
                Stepper("For \(Int(model.batteryOptions.readyDuration)) seconds", value: $model.batteryOptions.readyDuration, in: 1...60, step: 1)
                Text("Signals once when charge reaches your threshold while Battery is selected. Your brightness remains the upper limit.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

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
