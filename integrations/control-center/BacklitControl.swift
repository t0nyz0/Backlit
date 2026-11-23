import SwiftUI
import WidgetKit

@main
struct BacklitControlBundle: WidgetBundle {
    var body: some Widget {
        LogoLightControl()
    }
}

struct LogoLightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: LogoLightControlState.kind, provider: Provider()) { state in
            ControlWidgetToggle(
                "Logo Light",
                isOn: state.requestedEnabled,
                action: SetLogoLightControlIntent()
            ) { _ in
                Label(
                    state.requestedEnabled
                        ? (state.effectiveOutput ? "On" : "Enabled")
                        : "Off",
                    systemImage: state.effectiveOutput ? "lightbulb.fill" : "lightbulb"
                )
            }
        }
        .displayName("Logo Light")
        .description("Turn Backlit’s logo light on or off.")
    }

    struct Provider: ControlValueProvider {
        // This is a canned gallery preview only. Runtime state never defaults
        // to it when app-group access or the host observation is unavailable.
        var previewValue: LogoLightControlSnapshot {
            .init(requestedEnabled: false, effectiveOutput: false, available: true)
        }

        func currentValue() async throws -> LogoLightControlSnapshot {
            try LogoLightControlState.currentValue()
        }
    }
}
