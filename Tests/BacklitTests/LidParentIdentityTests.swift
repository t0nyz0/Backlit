import XCTest
@testable import Backlit

/// All process observations are injected values. These fixtures do not inspect,
/// start, stop or signal real processes and never enter the native lid watcher.
final class LidParentIdentityTests: XCTestCase {
    private let original = FadeProcessIdentity(pid: 123, seconds: 100, microseconds: 42)

    func testSuppliedIdentityMustMatchBeforeAdmissionAndEveryLaterCheck() throws {
        var observed: FadeProcessIdentity? = original
        var reads: [Int32] = []
        let read: (Int32) -> FadeProcessIdentity? = { reads.append($0); return observed }
        let owner = try XCTUnwrap(LidParentIdentity(parent: 123, supplied: original, read: read))
        XCTAssertEqual(reads, [123])
        XCTAssertTrue(owner.isAlive(read: read))
        observed = .init(pid: 123, seconds: 200, microseconds: 42)
        XCTAssertFalse(owner.isAlive(read: read), "An unrelated process owning the same PID is not the parent")
        XCTAssertEqual(reads, [123, 123, 123])
    }

    func testPIDReusedBeforeStartupRejectsNewCallersCapturedIdentity() {
        let reused = FadeProcessIdentity(pid: 123, seconds: 200, microseconds: 42)
        XCTAssertNil(LidParentIdentity(parent: 123, supplied: original, read: { _ in reused }))
    }

    func testMicrosecondsDistinguishProcessesStartedInTheSameSecond() throws {
        let owner = try XCTUnwrap(LidParentIdentity(parent: 123, supplied: original, read: { _ in self.original }))
        let reused = FadeProcessIdentity(pid: 123, seconds: 100, microseconds: 43)
        XCTAssertFalse(owner.isAlive(read: { _ in reused }))
        XCTAssertNil(LidParentIdentity(parent: 123, supplied: original, read: { _ in reused }))
    }

    func testMissingOrUnavailableParentFailsClosedAtEntryAndLater() throws {
        XCTAssertNil(LidParentIdentity(parent: 123, supplied: original, read: { _ in nil }))
        let owner = try XCTUnwrap(LidParentIdentity(parent: 123, supplied: original, read: { _ in self.original }))
        XCTAssertFalse(owner.isAlive(read: { _ in nil }))
    }

    func testMalformedOrMismatchedProcessObservationsAreRejected() {
        for invalid in [FadeProcessIdentity(pid: 0, seconds: 100, microseconds: 42),
                        .init(pid: -1, seconds: 100, microseconds: 42),
                        .init(pid: 123, seconds: 0, microseconds: 42),
                        .init(pid: 123, seconds: 100, microseconds: 1_000_000),
                        .init(pid: 456, seconds: 100, microseconds: 42)] {
            XCTAssertNil(LidParentIdentity(parent: 123, supplied: invalid, read: { _ in self.original }))
            XCTAssertNil(LidParentIdentity(parent: 123, read: { _ in invalid }))
        }
        XCTAssertNil(LidParentIdentity(parent: 0, read: { _ in XCTFail("Invalid PID must not be inspected"); return nil }))
        XCTAssertNil(LidParentIdentity(parent: -1, read: { _ in XCTFail("Invalid PID must not be inspected"); return nil }))
    }

    func testLegacyCallerSnapshotsOnceRatherThanFollowingAReusedPID() throws {
        var observed: FadeProcessIdentity? = original
        let owner = try XCTUnwrap(LidParentIdentity(parent: 123, read: { _ in observed }))
        observed = .init(pid: 123, seconds: 300, microseconds: 7)
        XCTAssertFalse(owner.isAlive(read: { _ in observed }))
    }

    func testLegacyEntryCannotProveIdentityBeforeItsInvocation() {
        // Backward compatibility has no pre-launch timestamp to compare. It
        // captures this process once; subsequent checks still reject reuse.
        let current = FadeProcessIdentity(pid: 123, seconds: 300, microseconds: 7)
        XCTAssertNotNil(LidParentIdentity(parent: 123, read: { _ in current }))
        XCTAssertNil(LidParentIdentity(parent: 123, supplied: original, read: { _ in current }))
    }

    func testReusedPIDIsRejectedWhileOpenEvenThoughDurationDoesNotLimitHelperLifetime() throws {
        let owner = try XCTUnwrap(LidParentIdentity(parent: 123, supplied: original, read: { _ in self.original }))
        let reused = FadeProcessIdentity(pid: 123, seconds: 400, microseconds: 8)
        let boot = UUID()
        var timer = LidLegacyContinuousTimer(duration: 1800)
        for now in [100.0, 1900, 86_400, 172_800] {
            XCTAssertTrue(timer.permits(closed: false, clock: .init(boot: boot, seconds: now)),
                "A verified open lid resets closure timing; the cap is not a helper-lifetime bound")
            XCTAssertFalse(owner.isAlive(read: { _ in reused }),
                "Liveness must withdraw independently of any closure deadline")
        }
    }

    func testIdentityArgumentsRoundTripWithAndWithoutSavedIntent() throws {
        let lease = URL(fileURLWithPath: "/tmp/backlit --parent-start session lease")
        let duration = LidSessionDuration(amount: 7)
        let intents: [UUID?] = [nil, UUID()]
        for intent in intents {
            let arguments = ["Backlit"] + duration.watcherArguments(parentIdentity: original, lease: lease, intent: intent)
            let parsed = try XCTUnwrap(LidWatcherArguments(arguments: arguments))
            XCTAssertEqual(parsed.parent, original.pid)
            XCTAssertEqual(parsed.parentIdentity, original)
            XCTAssertEqual(parsed.lease, lease)
            XCTAssertEqual(parsed.durationSeconds, 420)
            XCTAssertEqual(parsed.intent, intent)
        }
    }

    func testLegacyArgumentFormsRetainTheirDurationAndIntentWithoutInventingIdentity() throws {
        let intent = UUID()
        let base = ["Backlit", "--watch-lid", "123", "/tmp/lease"]
        for (suffix, seconds, saved) in [([String](), 1800.0, UUID?.none),
                                         (["90"], 90.0, nil),
                                         (["90", intent.uuidString], 90.0, intent)] {
            let parsed = try XCTUnwrap(LidWatcherArguments(arguments: base + suffix))
            XCTAssertEqual(parsed.durationSeconds, seconds)
            XCTAssertEqual(parsed.intent, saved)
            XCTAssertNil(parsed.parentIdentity)
        }
        let withIdentity = try XCTUnwrap(LidWatcherArguments(arguments: base + ["--parent-start", "100", "42"]))
        XCTAssertEqual(withIdentity.durationSeconds, 1800)
        XCTAssertEqual(withIdentity.parentIdentity, original)
    }

    func testMalformedIncompleteDuplicateAndMisplacedIdentitySuffixesAreRejected() {
        let base = ["Backlit", "--watch-lid", "123", "/tmp/lease", "1800"]
        for suffix in [["--parent-start"], ["--parent-start", "100"],
                       ["--parent-start", "100", "42", "extra"],
                       ["--parent-start", "100", "42", "--parent-start", "100", "42"],
                       ["--parent-start", "0", "0"], ["--parent-start", "-1", "0"],
                       ["--parent-start", "nan", "0"], ["--parent-start", "inf", "0"],
                       ["--parent-start", "1e3", "0"], ["--parent-start", "18446744073709551616", "0"],
                       ["--parent-start", "100", "-1"], ["--parent-start", "100", "0.5"],
                       ["--parent-start", "100", "1000000"],
                       ["--parent-startx", "100", "42"],
                       ["--parent-start", "100", "42", UUID().uuidString]] {
            XCTAssertNil(LidWatcherArguments(arguments: base + suffix), "Unexpectedly accepted: \(suffix)")
        }
    }

    func testIdentityMicrosecondBoundaryIsAccepted() throws {
        let parsed = try XCTUnwrap(LidWatcherArguments(arguments: ["Backlit", "--watch-lid", "123", "/tmp/lease", "1800",
            "--parent-start", "100", "999999"]))
        XCTAssertEqual(parsed.parentIdentity, FadeProcessIdentity(pid: 123, seconds: 100, microseconds: 999_999))
    }
}
