import XCTest
@testable import Backlit

/// Runs the real administrator script without administrator rights, against a
/// temporary folder and a throwaway settings domain. No system brightness
/// setting, privileged prompt or service restart is involved.
final class AmbientOverrideScriptTests: XCTestCase {
    private var directory: URL!
    private var domain: String!
    private let minimum = AmbientOverrideScript.keys[0], maximum = AmbientOverrideScript.keys[1]

    override func setUpWithError() throws {
        // The script takes only plain path characters, so avoid the temp
        // directory's symlinked /var prefix and any odd characters.
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        directory = base.appendingPathComponent("backlit-ambient-" + UUID().uuidString).appendingPathComponent("store")
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        domain = "local.backlit.test.ambient-script." + UUID().uuidString
    }
    override func tearDownWithError() throws {
        _ = try? tool("/usr/bin/defaults", ["delete", domain])
        // macOS keeps an empty file for a deleted domain; remove this test's own.
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent(domain + ".plist"))
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    @discardableResult private func tool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
    private func run(enabled: Bool, owner: UInt32? = nil, directory other: URL? = nil,
                     injectingFailure: ((String) -> String)? = nil) throws -> (status: Int32, output: String) {
        let script = try AmbientOverrideScript.make(enabled: enabled, directory: (other ?? directory).path, domain: domain,
            ownerID: owner ?? getuid(), restart: "/usr/bin/true")
        // Faults are injected only into this unprivileged, throwaway-domain test.
        // Production still invokes fixed system tools without injection hooks.
        return try tool("/bin/sh", ["-c", injectingFailure?(script) ?? script])
    }
    private func settings() throws -> [String: Any] {
        let file = directory.deletingLastPathComponent().appendingPathComponent("export-" + UUID().uuidString + ".plist")
        XCTAssertEqual(try tool("/usr/bin/defaults", ["export", domain, file.path]).status, 0)
        return try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] ?? [:]
    }
    private func write(_ key: String, _ fragment: String) throws {
        XCTAssertEqual(try tool("/usr/bin/defaults", ["write", domain, key, fragment]).status, 0)
    }
    private func numbers(_ value: Any?) -> [[Double]]? { (value as? [[NSNumber]])?.map { $0.map(\.doubleValue) } }
    private var backup: URL { directory.appendingPathComponent("ambient.plist") }
    private let originalMinimum = "<array><array><real>0</real><real>1.5</real></array><array><real>200</real><real>12.5</real></array><array><real>3.4028234663852886e+38</real><real>40</real></array></array>"

    func testRestartWaitsForOldServiceExitAndFailsClosed() throws {
        let handshake = AmbientOverrideScript.serviceRestart
            .replacingOccurrences(of: "/usr/bin/pgrep -x corebrightnessd", with: "discover")
            .replacingOccurrences(of: "/usr/bin/killall -TERM corebrightnessd", with: "restart")
            .replacingOccurrences(of: "/bin/kill -0", with: "probe")
            .replacingOccurrences(of: "/bin/sleep 0.1", with: ":")
        for (discovery, restart, probe, expected) in [
            ("echo 42", ":", "calls=$((calls + 1)); [ $calls -lt 4 ]", Int32(0)),
            ("echo 42", ":", "return 0", Int32(1)),
            ("echo 42", "return 1", "return 1", Int32(1)),
            ("return 2", ":", "return 1", Int32(1)),
            ("return 1", "exit 99", "exit 99", Int32(0))
        ] {
            let script = "set -eu; calls=0; fail() { echo \"$1\"; exit 1; }; " +
                "discover() { \(discovery); }; restart() { \(restart); }; probe() { \(probe); };\n" + handshake
            let result = try tool("/bin/sh", ["-c", script])
            XCTAssertEqual(result.status, expected, result.output)
        }
    }

    func testEnableSavesOriginalsOnceThenRestorePutsThemBack() throws {
        try write(minimum, originalMinimum)           // one limit exists, the other does not
        try write("UnrelatedSetting", "<integer>7</integer>")

        let enabled = try run(enabled: true)
        XCTAssertEqual(enabled.status, 0, enabled.output)
        var now = try settings()
        XCTAssertEqual(numbers(now[minimum]), [[0, 12.5], [Double(Float.greatestFiniteMagnitude), 12.5]])
        XCTAssertEqual(numbers(now[maximum]), [[0, 1000], [Double(Float.greatestFiniteMagnitude), 1000]])
        XCTAssertEqual(now["UnrelatedSetting"] as? Int, 7, "Other settings in the domain are not touched")
        let saved = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any]
        XCTAssertEqual(saved?.keys.sorted(), [minimum], "Only limits that existed are saved")
        XCTAssertEqual(numbers(saved?[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]])
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)

        // Enabling again must not overwrite the saved originals with the flat limits.
        XCTAssertEqual(try run(enabled: true).status, 0)
        let again = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any]
        XCTAssertEqual(numbers(again?[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]])

        let restored = try run(enabled: false)
        XCTAssertEqual(restored.status, 0, restored.output)
        now = try settings()
        XCTAssertEqual(numbers(now[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]])
        XCTAssertNil(now[maximum], "A limit that did not exist before is removed again")
        XCTAssertEqual(now["UnrelatedSetting"] as? Int, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "The saved copy is removed after a successful restore")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, [], "No working files are left behind")
    }

    func testBackupWrittenByTheEarlierHelperStillRestores() throws {
        // Versions up to 0.2.6 wrote this file from Swift. A Mac that has the
        // override switched on must be able to restore from it after updating.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let old: [String: Any] = [minimum: [[0.0, 2.0], [Double(Float.greatestFiniteMagnitude), 30.0]],
                                  maximum: [[0, 150], [1000, 600]]]
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0).write(to: backup)
        try write(minimum, AmbientOverrideScript.flatLimit("12.5"))
        try write(maximum, AmbientOverrideScript.flatLimit("1000"))

        let restored = try run(enabled: false)
        XCTAssertEqual(restored.status, 0, restored.output)
        let now = try settings()
        XCTAssertEqual(numbers(now[minimum]), [[0, 2], [Double(Float.greatestFiniteMagnitude), 30]])
        XCTAssertEqual(numbers(now[maximum]), [[0, 150], [1000, 600]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testFailedDeletionRetainsBackupAndSuccessfulRetryRestores() throws {
        try write(minimum, originalMinimum)
        XCTAssertEqual(try run(enabled: true).status, 0)
        let originalBackup = try Data(contentsOf: backup)

        let result = try run(enabled: false, injectingFailure: {
            $0.replacingOccurrences(of: "/usr/bin/defaults delete \"$domain\" \"$key\" >/dev/null 2>&1 || true",
                                    with: "/usr/bin/false || true")
        })
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("originally absent is still present"), result.output)
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
        XCTAssertNotNil(try settings()[maximum], "The failed deletion really left the override in place")

        let retried = try run(enabled: false)
        XCTAssertEqual(retried.status, 0, retried.output)
        XCTAssertNil(try settings()[maximum])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testOriginallyAbsentKeyAlreadyRemovedIsSuccessful() throws {
        try write(minimum, originalMinimum)
        XCTAssertEqual(try run(enabled: true).status, 0)
        XCTAssertEqual(try tool("/usr/bin/defaults", ["delete", domain, maximum]).status, 0)

        let result = try run(enabled: false)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertNil(try settings()[maximum])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testSilentWriteFailureIsDetectedByReadbackAndRetainsBackup() throws {
        try write(minimum, originalMinimum)
        XCTAssertEqual(try run(enabled: true).status, 0)
        let originalBackup = try Data(contentsOf: backup)

        let result = try run(enabled: false, injectingFailure: {
            $0.replacingOccurrences(of: "/usr/bin/defaults write \"$domain\" \"$key\" \"$saved\"",
                                    with: "/usr/bin/true")
        })
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("did not match"), result.output)
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
        XCTAssertEqual(numbers(try settings()[minimum]), [[0, 12.5], [Double(Float.greatestFiniteMagnitude), 12.5]])
    }

    func testReadbackFailureRetainsBackupEvenAfterWritesSucceed() throws {
        try write(minimum, originalMinimum)
        XCTAssertEqual(try run(enabled: true).status, 0)
        let originalBackup = try Data(contentsOf: backup)

        let result = try run(enabled: false, injectingFailure: {
            $0.replacingOccurrences(of: "/usr/bin/defaults export \"$domain\" \"$work/restored.plist\"",
                                    with: "/usr/bin/false")
        })
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("could not be read"), result.output)
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
        XCTAssertEqual(numbers(try settings()[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]])

        let retried = try run(enabled: false)
        XCTAssertEqual(retried.status, 0, retried.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testPartialWriteFailureRetainsCompleteBackupForRetry() throws {
        try write(minimum, originalMinimum)
        try write(maximum, AmbientOverrideScript.flatLimit("500"))
        XCTAssertEqual(try run(enabled: true).status, 0)
        let originalBackup = try Data(contentsOf: backup)

        let result = try run(enabled: false, injectingFailure: {
            $0.replacingOccurrences(of: "/usr/bin/defaults write \"$domain\" \"$key\" \"$saved\"",
                                    with: "if [ \"$key\" = \"\(self.maximum)\" ]; then /usr/bin/false; else /usr/bin/defaults write \"$domain\" \"$key\" \"$saved\"; fi")
        })
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
        let partial = try settings()
        XCTAssertEqual(numbers(partial[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]])
        XCTAssertEqual(numbers(partial[maximum]), [[0, 1000], [Double(Float.greatestFiniteMagnitude), 1000]])

        let retried = try run(enabled: false)
        XCTAssertEqual(retried.status, 0, retried.output)
        XCTAssertEqual(numbers(try settings()[maximum]), [[0, 500], [Double(Float.greatestFiniteMagnitude), 500]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRestoreWithoutASavedCopyFailsAndChangesNothing() throws {
        try write(minimum, originalMinimum)
        let result = try run(enabled: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("No saved brightness limits to restore."), result.output)
        XCTAssertEqual(numbers(try settings()[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]])
    }

    func testUnreadableSavedCopyIsLeftUntouched() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("not a property list".utf8).write(to: backup)
        try write(minimum, AmbientOverrideScript.flatLimit("12.5"))
        let result = try run(enabled: false)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("unreadable"), result.output)
        XCTAssertEqual(try Data(contentsOf: backup), Data("not a property list".utf8))
        XCTAssertEqual(numbers(try settings()[minimum]), [[0, 12.5], [Double(Float.greatestFiniteMagnitude), 12.5]], "Limits are not changed either")
    }

    func testWrongOwnerSymlinkedFolderAndSymlinkedSavedCopyAreRefused() throws {
        try write(minimum, originalMinimum)
        // A folder owned by someone other than the expected account.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var result = try run(enabled: true, owner: getuid() &+ 1)
        XCTAssertNotEqual(result.status, 0); XCTAssertTrue(result.output.contains("Invalid recovery directory."), result.output)
        // A symbolic link standing in for the folder.
        let link = directory.deletingLastPathComponent().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        result = try run(enabled: true, directory: link)
        XCTAssertNotEqual(result.status, 0); XCTAssertTrue(result.output.contains("Invalid recovery directory."), result.output)
        // A symbolic link standing in for the saved copy.
        let elsewhere = directory.deletingLastPathComponent().appendingPathComponent("elsewhere.plist")
        try Data("x".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: elsewhere)
        result = try run(enabled: true)
        XCTAssertNotEqual(result.status, 0); XCTAssertTrue(result.output.contains("Invalid recovery file."), result.output)
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("x".utf8))
        XCTAssertEqual(numbers(try settings()[minimum]), [[0, 1.5], [200, 12.5], [Double(Float.greatestFiniteMagnitude), 40]], "Nothing was changed by any refused run")
    }

    func testScriptRunsOnlySystemToolsByAbsolutePathAndNeverTheApp() throws {
        for enabled in [true, false] {
            let script = try AmbientOverrideScript.make(enabled: enabled)
            XCTAssertTrue(script.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
            XCTAssertTrue(script.contains("dir='/var/db/local.backlit'"))
            XCTAssertTrue(script.contains("domain='com.apple.CoreBrightness'"))
            XCTAssertTrue(script.contains("/usr/bin/killall -TERM corebrightnessd"))
            XCTAssertFalse(script.contains("Backlit.app"), "The app bundle is never referenced")
            XCTAssertFalse(script.contains("--ambient-helper"))
            XCTAssertFalse(script.contains(Bundle.main.bundlePath))
            // Every external command is one of these system tools, by absolute path.
            let allowed: Set<String> = ["/usr/bin/stat", "/bin/mkdir", "/usr/bin/mktemp", "/bin/rm", "/usr/bin/sed",
                "/usr/bin/defaults", "/usr/bin/plutil", "/usr/bin/cmp", "/bin/chmod", "/bin/mv", "/usr/bin/killall", "/usr/bin/pgrep", "/bin/kill", "/bin/sleep"]
            let used = Set(script.components(separatedBy: CharacterSet(charactersIn: " \n\"'()`;|&$")).filter { $0.hasPrefix("/usr/") || $0.hasPrefix("/bin/") })
            XCTAssertTrue(used.isSubset(of: allowed.union(["/usr/bin:/bin:/usr/sbin:/sbin"])), "Unexpected tool: \(used.subtracting(allowed))")
            for path in allowed where used.contains(path) {
                let owner = try FileManager.default.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber
                XCTAssertEqual(owner?.intValue, 0, "\(path) must be a system-owned tool")
            }
        }
    }

    func testOnlyPlainSettingsCanBeInterpolatedIntoTheScript() {
        XCTAssertThrowsError(try AmbientOverrideScript.make(enabled: true, directory: "/tmp/x'; rm -rf /; '"))
        XCTAssertThrowsError(try AmbientOverrideScript.make(enabled: true, directory: "relative/path"))
        XCTAssertThrowsError(try AmbientOverrideScript.make(enabled: true, directory: "/var/db/../etc"))
        XCTAssertThrowsError(try AmbientOverrideScript.make(enabled: true, domain: "com.apple; reboot"))
        XCTAssertThrowsError(try AmbientOverrideScript.make(enabled: true, restart: "killall corebrightnessd"))
        XCTAssertThrowsError(try AmbientOverrideScript.make(enabled: true, restart: "/usr/bin/true; reboot"))
        XCTAssertNoThrow(try AmbientOverrideScript.make(enabled: false))
    }

    func testAppleScriptSourceEscapesTheScriptAndCompiles() throws {
        XCTAssertEqual(AmbientOverrideScript.appleScriptLiteral("a\"b\\c\nd"), "a\\\"b\\\\c\\nd")
        for enabled in [true, false] {
            let shell = try AmbientOverrideScript.make(enabled: enabled)
            let privileged = AmbientOverrideScript.appleScript(enabled: enabled, shell: shell)
            XCTAssertTrue(privileged.hasPrefix("do shell script \""))
            XCTAssertTrue(privileged.hasSuffix("with administrator privileges"))
            XCTAssertTrue(privileged.contains(enabled ? "wants to unlock" : "wants to restore"))
            XCTAssertFalse(privileged.contains("\n"), "The script is passed as one escaped string literal")
            // Compiling parses the literal without running anything or prompting.
            var error: NSDictionary?
            let compiled = NSAppleScript(source: privileged)?.compileAndReturnError(&error)
            XCTAssertEqual(compiled, true, "\(String(describing: error))")
        }
    }
}
