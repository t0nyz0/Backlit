import Foundation
import Combine
#if BACKLIT_CONTROL_CENTER
import WidgetKit

/// Experimental only. Normal ad-hoc builds neither start this publisher nor
/// embed the extension. No state-sharing entitlement is added to shipping builds.
@available(macOS 26.0, *)
@MainActor final class BacklitControlHost {
    static let shared = BacklitControlHost()
    private weak var model: AppModel?
    private var timer: Timer?
    private var observation: AnyCancellable?
    private var last: BacklitControlSnapshot?

    func start(model: AppModel) {
        guard !model.demo else { return }
        self.model = model
        BacklitControlBridge.setPower = { [weak self, weak model] value in
            guard let self, let model else { throw AutomationError.unavailable }
            _ = try BacklitControlState.currentValue()
            // The native intent never skips existing recovery/lifecycle gates.
            try model.performControlCenterPower(value)
            self.publish()
        }
        observation = model.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in self?.publish() } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        publish()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        observation = nil
        BacklitControlBridge.setPower = nil
        model = nil; last = nil
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BacklitControlState.groupIdentifier) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent(BacklitControlState.filename))
        }
        ControlCenter.shared.reloadControls(ofKind: BacklitControlState.kind)
    }

    private func publish() {
        guard let model,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BacklitControlState.groupIdentifier) else { return }
        let value = model.controlCenterObservation()
        let sample = BacklitControlSnapshot(requestedEnabled: value.requested,
            effectiveOutput: value.effective, available: value.available, observedAt: Date())
        let url = container.appendingPathComponent(BacklitControlState.filename)
        do {
            let data = try JSONEncoder().encode(sample)
            try data.write(to: url, options: .atomic)
            // Only non-sensitive state is shared; never preferences, credentials,
            // diagnostics, paths, audio data or session identifiers.
            if last?.requestedEnabled != sample.requestedEnabled || last?.effectiveOutput != sample.effectiveOutput || last?.available != sample.available {
                ControlCenter.shared.reloadControls(ofKind: BacklitControlState.kind)
            }
            last = sample
        } catch {
            // Do not publish successful-looking fallback state. Existing sample
            // is rejected after 60s when queried. WidgetKit may retain a cached
            // display until its next reload; freshness is not a display timer.
        }
    }
}
#endif
