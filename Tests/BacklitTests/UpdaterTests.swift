import XCTest
import CryptoKit
import Sparkle
@testable import Backlit

final class UpdaterTests: XCTestCase {
    private func configuration() -> [String: Any] {
        ["SUFeedURL": "https://t0nyz.com/backlit/appcast.xml",
         "SUPublicEDKey": Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
         "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
         "SUSignedFeedFailureExpirationInterval": 0, "SUEnableAutomaticChecks": false,
         "SUAllowsAutomaticUpdates": false, "SUAutomaticallyUpdate": false, "SUEnableSystemProfiling": false]
    }
    func testMissingOrWeakenedTrustNeverEnablesTheUpdater() throws {
        let valid = configuration()
        XCTAssertNoThrow(try UpdateConfiguration(info: valid, preview: false))
        XCTAssertThrowsError(try UpdateConfiguration(info: valid, preview: true))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try UpdateConfiguration(info: missing, preview: false), key)
        }
        for key in ["SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            var weak = valid; weak[key] = false
            XCTAssertThrowsError(try UpdateConfiguration(info: weak, preview: false))
        }
        for key in ["SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableSystemProfiling"] {
            var weak = valid; weak[key] = true
            XCTAssertThrowsError(try UpdateConfiguration(info: weak, preview: false))
        }
        var expiring = valid; expiring["SUSignedFeedFailureExpirationInterval"] = 1
        XCTAssertThrowsError(try UpdateConfiguration(info: expiring, preview: false))
    }
    func testInvalidFeedAndPublicKeyAreRejected() {
        for url in ["http://t0nyz.com/feed", "file:///tmp/feed", "https://user:secret@t0nyz.com/feed", "https://t0nyz.com:444/feed", "https://t0nyz.com/feed?token=test", "https://t0nyz.com/feed#key"] {
            var info = configuration(); info["SUFeedURL"] = url
            XCTAssertThrowsError(try UpdateConfiguration(info: info, preview: false))
        }
        for key in ["", "untrusted-checksum", Data(repeating: 0, count: 32).base64EncodedString(), Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = configuration(); info["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdateConfiguration(info: info, preview: false))
        }
    }
    func testCandidateMustBeNewerAndMatchArchitectureAndRepository() throws {
        let valid = URL(string: "https://github.com/t0nyz0/Backlit/releases/download/v0.2.1/Backlit-0.2.1-macOS-arm64.zip")!
        XCTAssertNoThrow(try UpdateConfiguration.validateAsset(valid, build: "22", current: "21", architecture: "arm64"))
        for build in ["21", "20", "-1", "22x", "18446744073709551616"] {
            XCTAssertThrowsError(try UpdateConfiguration.validateAsset(valid, build: build, current: "21", architecture: "arm64"))
        }
        XCTAssertThrowsError(try UpdateConfiguration.validateAsset(valid, build: "22", current: "21", architecture: "x86_64"))
        for raw in ["http://github.com/t0nyz0/Backlit/releases/download/v1/Backlit-macOS-arm64.zip", "https://github.com/attacker/Backlit/releases/download/v1/Backlit-macOS-arm64.zip", "https://github.com/t0nyz0/Backlit/releases/download/v1/Backlit-macOS-arm64.pkg", valid.absoluteString + "?token=test"] {
            XCTAssertThrowsError(try UpdateConfiguration.validateAsset(URL(string: raw), build: "22", current: "21", architecture: "arm64"))
        }
    }
    @MainActor func testRestorationFailureDefersInstallAndRetryRunsExactlyOnce() {
        let gate = UpdateInstallGate()
        var ready = false, calls = 0
        gate.prepare = { ready }
        XCTAssertTrue(gate.postpone { calls += 1 })
        gate.retry(); gate.retry(); XCTAssertEqual(calls, 0)
        ready = true
        gate.retry(); gate.retry(); XCTAssertEqual(calls, 1)
        XCTAssertFalse(gate.paused)
    }
    @MainActor func testAbortDropsPendingInstallAndMissingCleanupFailsClosed() {
        let gate = UpdateInstallGate()
        var calls = 0
        XCTAssertTrue(gate.postpone { calls += 1 })
        gate.clear(); gate.prepare = { true }; gate.retry()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(gate.postpone { calls += 1 })
        XCTAssertEqual(calls, 0, "Sparkle owns the continuation when no postponement is needed")
    }
    @MainActor func testUnconfiguredCheckDoesNotCreateNetworkSessionOrModifyPreferences() {
        let updater = AppUpdater()
        updater.check(preview: true); updater.check(preview: true)
        XCTAssertNotNil(updater.message)
        XCTAssertTrue(updater.canCheck)
        XCTAssertFalse(updater.installPaused)
    }
    func testResumeWithoutRelaunchCannotBypassInstallConsent() {
        var policy = UpdateConsent()
        XCTAssertTrue(policy.allowsTermination)
        policy.arm() // Resumed install: no postponement callback or fresh choice.
        XCTAssertFalse(policy.allowsTermination)
        policy.approve()
        XCTAssertTrue(policy.allowsTermination)
        policy.reset(); policy.arm()
        XCTAssertFalse(policy.allowsTermination, "An earlier choice must not approve a different session")
    }
    func testSparkleVersionComparatorRejectsOlderAndSameBuilds() {
        let comparator = SUStandardVersionComparator.default
        XCTAssertEqual(comparator.compareVersion("21", toVersion: "22"), .orderedAscending)
        XCTAssertEqual(comparator.compareVersion("21", toVersion: "21"), .orderedSame)
        XCTAssertEqual(comparator.compareVersion("22", toVersion: "21"), .orderedDescending)
    }
}
