import SwiftUI
import WidgetKit

@main
struct BacklitControlBundle: WidgetBundle {
    var body: some Widget {
        BacklitPowerControl()
    }
}

struct BacklitPowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: BacklitControlState.kind, provider: Provider()) { state in
            ControlWidgetToggle(
                "Backlit",
                isOn: state.requestedEnabled,
                action: SetBacklitControlPowerIntent()
            ) { _ in
                Label(
                    state.requestedEnabled
                        ? (state.effectiveOutput ? "On" : "Enabled")
                        : "Off",
                    systemImage: state.effectiveOutput ? "lightbulb.fill" : "lightbulb"
                )
            }
        }
        .displayName("Backlit")
        .description("Turn your MacBook’s backlit logo on or off.")
    }

    struct Provider: ControlValueProvider {
        // This is a canned gallery preview only. Runtime state never defaults
        // to it when app-group access or the host observation is unavailable.
        var previewValue: BacklitControlSnapshot {
            .init(requestedEnabled: false, effectiveOutput: false, available: true)
        }

        func currentValue() async throws -> BacklitControlSnapshot {
            try BacklitControlState.currentValue()
        }
    }
}
