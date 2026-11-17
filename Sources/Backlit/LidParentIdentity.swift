import Foundation

/// Bind one helper to the actual parent process, not a PID that macOS may reuse.
/// Legacy callers capture the observed identity at entry; new callers also prove
/// that it matches the identity captured before launching the helper.
struct LidParentIdentity {
    private let identity: FadeProcessIdentity

    init?(parent: Int32, supplied: FadeProcessIdentity? = nil,
          read: (Int32) -> FadeProcessIdentity? = FadeProcessIdentity.read) {
        guard parent > 0, let current = read(parent), Self.valid(current), current.pid == parent,
              supplied.map({ Self.valid($0) && $0.pid == parent && $0 == current }) ?? true else { return nil }
        identity = current
    }

    func isAlive(read: (Int32) -> FadeProcessIdentity? = FadeProcessIdentity.read) -> Bool {
        read(identity.pid) == identity
    }

    private static func valid(_ identity: FadeProcessIdentity) -> Bool {
        identity.pid > 0 && identity.seconds > 0 && identity.microseconds < 1_000_000
    }
}
