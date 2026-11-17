import XCTest
@testable import Backlit

final class AgentHookStatusTests: XCTestCase {
    private let binary = "/fixture/My App's/Backlit"

    private func document(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encoded(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document)
    }

    private func installed(_ data: Data, agent: CodingAgent, executable: Bool = true) -> Bool {
        AgentBridge.hooksInstalled(data, agent: agent, binaries: [binary], isExecutable: { _ in executable })
    }

    func testCompleteGeneratedV2HooksForBothAgentsAreInstalledWithoutConfigurationChanges() throws {
        for agent in CodingAgent.allCases {
            let data = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary)
            var checked: [String] = []
            XCTAssertTrue(AgentBridge.hooksInstalled(data, agent: agent, binaries: [binary], isExecutable: {
                checked.append($0); return $0 == self.binary
            }))
            XCTAssertEqual(checked, [binary])
            XCTAssertEqual(data, try AgentBridge.merged(data, agent: agent, enabled: true, binary: binary))
        }
    }

    func testMarkerInUnrelatedTextMalformedOrPartialConfigurationIsNotInstalled() throws {
        for agent in CodingAgent.allCases {
            let marker = "--backlit-hook " + agent.rawValue
            for text in ["not JSON " + marker, "[\"" + marker + "\"]",
                         "{\"note\":\"" + marker + "\"}",
                         "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo " + marker + "\"}]}]}}"] {
                XCTAssertFalse(installed(Data(text.utf8), agent: agent))
            }
            let complete = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary)
            var partial = try document(complete)
            var hooks = try XCTUnwrap(partial["hooks"] as? [String: Any])
            hooks.removeValue(forKey: "PermissionRequest")
            partial["hooks"] = hooks
            XCTAssertFalse(installed(try encoded(partial), agent: agent))
        }
    }

    func testNonExecutableRelativeUnknownAndMixedBinaryTargetsAreNotInstalled() throws {
        for agent in CodingAgent.allCases {
            let complete = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary)
            XCTAssertFalse(installed(complete, agent: agent, executable: false))
            XCTAssertFalse(AgentBridge.hooksInstalled(complete, agent: agent, binaries: ["/different/Backlit"], isExecutable: { _ in true }))
            let relative = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: "relative/Backlit")
            XCTAssertFalse(AgentBridge.hooksInstalled(relative, agent: agent, binaries: ["relative/Backlit"], isExecutable: { _ in true }))
            var mixed = try document(complete)
            var hooks = try XCTUnwrap(mixed["hooks"] as? [String: Any])
            hooks["Stop"] = [["hooks": [["type": "command", "command": AgentBridge.command(agent, "waiting", binary: "/other/Backlit")]]]]
            mixed["hooks"] = hooks
            XCTAssertFalse(AgentBridge.hooksInstalled(try encoded(mixed), agent: agent,
                binaries: [binary, "/other/Backlit"], isExecutable: { _ in true }))
        }
    }

    func testWrongPhaseTypeAndConditionalHooksAreNotInstalled() throws {
        for agent in CodingAgent.allCases {
            let complete = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary)
            for override in [["command": AgentBridge.command(agent, "working", binary: binary)],
                             ["type": "prompt"]] as [[String: Any]] {
                var changed = try document(complete)
                var hooks = try XCTUnwrap(changed["hooks"] as? [String: Any])
                var entry: [String: Any] = ["type": "command", "command": AgentBridge.command(agent, "waiting", binary: binary), "timeout": 3]
                entry.merge(override) { _, new in new }
                hooks["Stop"] = [["hooks": [entry]]]
                changed["hooks"] = hooks
                XCTAssertFalse(installed(try encoded(changed), agent: agent))
            }
            for groupFlag in [["matcher": "custom-only"]] as [[String: Any]] {
                var changed = try document(complete)
                var hooks = try XCTUnwrap(changed["hooks"] as? [String: Any])
                var group: [String: Any] = ["hooks": [["type": "command", "command": AgentBridge.command(agent, "waiting", binary: binary)]]]
                group.merge(groupFlag) { _, new in new }
                hooks["Stop"] = [group]
                changed["hooks"] = hooks
                XCTAssertFalse(installed(try encoded(changed), agent: agent))
            }
            var globallyDisabled = try document(complete)
            globallyDisabled["disableAllHooks"] = true
            XCTAssertFalse(installed(try encoded(globallyDisabled), agent: agent))
        }
    }

    func testExtraCustomHooksDoNotInvalidateOrMutateCompleteKnownInstallation() throws {
        for agent in CodingAgent.allCases {
            let complete = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary)
            var customized = try document(complete)
            var hooks = try XCTUnwrap(customized["hooks"] as? [String: Any])
            var groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
            var generated = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
            generated[0]["async"] = true
            generated[0]["timeout"] = 17
            groups[0]["hooks"] = generated
            groups.insert(["matcher": "custom", "hooks": [["type": "command", "command": "echo user-hook"]]], at: 0)
            hooks["Stop"] = groups
            hooks["FutureEvent"] = [["hooks": [["type": "command", "command": "echo future-hook"]]]]
            customized["hooks"] = hooks
            customized["note"] = "user-owned value"
            let data = try encoded(customized)
            XCTAssertTrue(installed(data, agent: agent))
            XCTAssertEqual(try document(data) as NSDictionary, customized as NSDictionary)
        }
    }

    func testLegacyOnlyAndCustomizedCommandsAreNotReportedAsCurrentV2Installation() throws {
        for agent in CodingAgent.allCases {
            var old = try document(AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary))
            var hooks = try XCTUnwrap(old["hooks"] as? [String: Any])
            hooks["Stop"] = [["hooks": [["type": "command", "command": "/usr/bin/pgrep -xq Backlit || exit 0; " + AgentBridge.shellArgument(binary) + " --backlit-hook " + agent.rawValue + " waiting $sid"]]]]
            old["hooks"] = hooks
            XCTAssertFalse(installed(try encoded(old), agent: agent))
        }
    }

    func testPartialStaleAndDisabledCurrentHooksRetainDisconnect() throws {
        for agent in CodingAgent.allCases {
            let complete = try AgentBridge.merged(nil, agent: agent, enabled: true, binary: binary)
            let full = AgentBridge.inspectHooks(complete, agent: agent, binaries: [binary], isExecutable: { _ in true })
            XCTAssertTrue(full.fullyInstalled)
            XCTAssertTrue(full.hasManagedHooks)
            XCTAssertTrue(full.canDisconnect)
            let stale = AgentBridge.inspectHooks(complete, agent: agent, binaries: [binary], isExecutable: { _ in false })
            XCTAssertFalse(stale.fullyInstalled)
            XCTAssertTrue(stale.hasManagedHooks)
            XCTAssertTrue(stale.canDisconnect)
            var partial = try document(complete)
            var hooks = try XCTUnwrap(partial["hooks"] as? [String: Any])
            hooks.removeValue(forKey: "PermissionRequest")
            partial["hooks"] = hooks
            let incomplete = AgentBridge.inspectHooks(try encoded(partial), agent: agent, binaries: [binary], isExecutable: { _ in true })
            XCTAssertFalse(incomplete.fullyInstalled)
            XCTAssertTrue(incomplete.canDisconnect)
            var disabled = try document(complete)
            disabled["disableAllHooks"] = true
            let inactive = AgentBridge.inspectHooks(try encoded(disabled), agent: agent, binaries: [binary], isExecutable: { _ in true })
            XCTAssertFalse(inactive.fullyInstalled)
            XCTAssertTrue(inactive.canDisconnect)
        }
    }

    func testExactLegacyAndWrongPhaseHooksAreRemovableWithoutBeingComplete() throws {
        for agent in CodingAgent.allCases {
            let legacy = "/usr/bin/pgrep -xq Backlit || exit 0; " + AgentBridge.shellArgument(binary)
                + " --backlit-hook " + agent.rawValue + " waiting $sid"
            for command in [legacy, AgentBridge.command(agent, "working", binary: binary)] {
                let configuration: [String: Any] = ["hooks": ["Stop": [["matcher": "custom-only", "hooks": [["type": "command", "command": command]]]]]]
                let data = try encoded(configuration)
                let status = AgentBridge.inspectHooks(data, agent: agent, binaries: [binary], isExecutable: { _ in false })
                XCTAssertFalse(status.fullyInstalled)
                XCTAssertTrue(status.hasManagedHooks)
                XCTAssertTrue(status.canDisconnect)
                let removed = try AgentBridge.merged(data, agent: agent, enabled: false, binary: binary)
                XCTAssertNil(try document(removed)["hooks"], "Disconnect must remove the exactly owned command")
            }
        }
    }

    func testAbsentUnknownAndMixedShellCommandsAreNotClaimedAsRemovable() throws {
        for agent in CodingAgent.allCases {
            for command in ["echo --backlit-hook " + agent.rawValue,
                            AgentBridge.command(agent, "waiting", binary: binary) + "; echo user-maintenance",
                            AgentBridge.command(agent, "waiting", binary: "/unknown/Backlit")] {
                let configuration: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": command]]]]]]
                let data = try encoded(configuration)
                XCTAssertEqual(AgentBridge.inspectHooks(data, agent: agent, binaries: [binary], isExecutable: { _ in true }), .absent)
                XCTAssertEqual(try document(AgentBridge.merged(data, agent: agent, enabled: false, binary: binary)) as NSDictionary,
                    configuration as NSDictionary, "Unknown/custom work must remain untouched")
            }
            XCTAssertEqual(AgentBridge.inspectHooks(Data("{}".utf8), agent: agent, binaries: [binary], isExecutable: { _ in true }), .absent)
            XCTAssertEqual(AgentBridge.inspectHooks(Data("not JSON".utf8), agent: agent, binaries: [binary], isExecutable: { _ in true }), .absent)
        }
    }
}
