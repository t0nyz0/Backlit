import AppKit

/// AppKit's terminateLater enters a nested modal run loop. Enter termination
/// from a run-loop source, not a main-queue task whose pending cleanup blocks
/// cannot execute recursively on the same serial queue.
@MainActor final class QuitRunLoop {
    private var scheduled = false

    func request(_ terminate: @escaping @MainActor () -> Void) {
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.scheduled = false }
                terminate()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
