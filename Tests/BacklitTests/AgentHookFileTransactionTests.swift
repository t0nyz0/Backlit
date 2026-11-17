import XCTest
@testable import Backlit

final class AgentHookFileTransactionTests: XCTestCase {
    private let binary = "/inert-fixture/Backlit"
    private enum InjectedFailure: Error { case stopped }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func stagedFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".backlit-hooks-") }
    }
    func testMissingDisconnectDoesNotCreateConfigurationOrBackupDirectory() throws {
        let directory = try temporaryDirectory(), file = directory.appendingPathComponent("settings.json")
        let backups = directory.appendingPathComponent("backups")
        var reachedCommit = false
        XCTAssertFalse(try AgentBridge.saveHooks(at: file, agent: .claude, enabled: false, binary: binary,
            backupDirectory: backups, beforeCommit: { reachedCommit = true }))
        XCTAssertFalse(reachedCommit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testInitialConfigurationIsStagedPrivatelyAndCommittedCompletely() throws {
        let directory = try temporaryDirectory(), file = directory.appendingPathComponent("hooks.json")
        var inspectedStage = false
        XCTAssertTrue(try AgentBridge.saveHooks(at: file, agent: .codex, enabled: true, binary: binary,
            backupDirectory: directory.appendingPathComponent("backups"), beforeCommit: {
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                let stages = try self.stagedFiles(in: directory)
                XCTAssertEqual(stages.count, 1)
                let staged = directory.appendingPathComponent(try XCTUnwrap(stages.first))
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions] as? Int, 0o600)
                XCTAssertEqual(try Data(contentsOf: staged), try AgentBridge.merged(nil, agent: .codex, enabled: true, binary: self.binary))
                inspectedStage = true
            }))
        XCTAssertTrue(inspectedStage)
        XCTAssertEqual(try Data(contentsOf: file), try AgentBridge.merged(nil, agent: .codex, enabled: true, binary: binary))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }
    func testExternalConfigurationCreatedAtCommitWindowIsNeverOverwritten() throws {
        for agent in CodingAgent.allCases {
            let directory = try temporaryDirectory(), file = directory.appendingPathComponent(agent.file)
            let external = Data(#"{"permissions":{"allow":["external-owner"]},"hooks":{}}"#.utf8)
            XCTAssertThrowsError(try AgentBridge.saveHooks(at: file, agent: agent, enabled: true, binary: binary,
                backupDirectory: directory.appendingPathComponent("backups"), beforeCommit: {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                    XCTAssertEqual(try self.stagedFiles(in: directory).count, 1)
                    try external.write(to: file, options: .atomic)
                })) { error in XCTAssertTrue(error.localizedDescription.contains("Nothing was overwritten")) }
            XCTAssertEqual(try Data(contentsOf: file), external)
            XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("backups").path).isEmpty)
        }
    }
    func testExternalSymlinkAtCommitWindowAndItsTargetArePreserved() throws {
        let directory = try temporaryDirectory(), file = directory.appendingPathComponent("settings.json")
        let target = directory.appendingPathComponent("external-target")
        let external = Data("external target must remain unchanged".utf8)
        try external.write(to: target)
        XCTAssertThrowsError(try AgentBridge.saveHooks(at: file, agent: .claude, enabled: true, binary: binary,
            backupDirectory: directory.appendingPathComponent("backups"), beforeCommit: {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            }))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), target.path)
        XCTAssertEqual(try Data(contentsOf: target), external)
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }
    func testAbortedInitialCommitCleansStageWithoutCreatingFinalFile() throws {
        let directory = try temporaryDirectory(), file = directory.appendingPathComponent("settings.json")
        XCTAssertThrowsError(try AgentBridge.saveHooks(at: file, agent: .claude, enabled: true, binary: binary,
            backupDirectory: directory.appendingPathComponent("backups"), beforeCommit: { throw InjectedFailure.stopped }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }
    func testExistingConfigurationKeepsUnrelatedDataModeAndExactBackup() throws {
        let directory = try temporaryDirectory(), file = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"permissions":{"allow":["external-owner"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo unrelated"}]}]}}"#.utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let backups = directory.appendingPathComponent("backups")
        XCTAssertTrue(try AgentBridge.saveHooks(at: file, agent: .claude, enabled: true, binary: binary, backupDirectory: backups))
        let updated = try Data(contentsOf: file)
        XCTAssertEqual(updated, try AgentBridge.merged(original, agent: .claude, enabled: true, binary: binary))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o640)
        let backupFiles = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(backupFiles.count, 1)
        let backup = try XCTUnwrap(backupFiles.first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }
    func testMalformedExistingConfigurationRemainsUntouchedWithoutBackup() throws {
        let directory = try temporaryDirectory(), file = directory.appendingPathComponent("settings.json")
        let original = Data("not a configuration".utf8), backups = directory.appendingPathComponent("backups")
        try original.write(to: file)
        XCTAssertThrowsError(try AgentBridge.saveHooks(at: file, agent: .claude, enabled: true, binary: binary, backupDirectory: backups))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        XCTAssertTrue(try stagedFiles(in: directory).isEmpty)
    }
}
