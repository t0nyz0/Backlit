import Foundation

/// Recheck visibility after AppKit finishes a launch or activation turn.
/// Scheduling and native operations are injected so regression tests open no UI.
@MainActor final class AppIconVisibilityReconciler {
    private let requested: () -> AppIconVisibility
    private let isApplied: (AppIconVisibility) -> Bool
    private let apply: () -> Void
    private let enqueue: (@escaping () -> Void) -> Void
    private var enabled = false
    private var pending = false
    private var applying = false
    init(requested: @escaping () -> AppIconVisibility,
         isApplied: @escaping (AppIconVisibility) -> Bool,
         apply: @escaping () -> Void,
         enqueue: @escaping (@escaping () -> Void) -> Void) {
        self.requested = requested; self.isApplied = isApplied
        self.apply = apply; self.enqueue = enqueue
    }
    func start() {
        guard !enabled else { return }
        enabled = true
        request()
    }
    func request() {
        guard enabled, !pending, !applying else { return }
        // Do not skip an apparently-correct state here: AppKit may change the
        // activation policy after the caller returns from launch/activation.
        pending = true
        enqueue { [weak self] in
            guard let self else { return }
            defer { self.pending = false }
            let desired = self.requested()
            guard !self.isApplied(desired) else { return }
            self.applying = true
            defer { self.applying = false }
            self.apply()
        }
    }
}
