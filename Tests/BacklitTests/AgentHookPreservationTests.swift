import XCTest
@testable import Backlit

final class AgentHookPreservationTests: XCTestCase {
    private let oldBinary = "/old/My App's/Backlit"
    private let newBinary = "/new/Backlit"

    private func legacy(_ agent: CodingAgent, phase: String = "working", binary: String? = nil) -> String {
        "/usr/bin/pgrep -xq Backlit || exit 0; " + AgentBridge.shellArgument(binary ?? oldBinary)
            + " --backlit-hook " + agent.rawValue + " " + phase + " $sid"
    }

    private func configuration(command: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "permissions": ["allow": ["Bash(ls)"]],
            "hooks": ["Stop": [[
                "matcher": "user-matcher",
                "hooks": [["type": "command", "command": command, "timeout": 17],
                          ["type": "command", "command": "echo another-user-hook"]]
            ]]]
        ])
    }

    private func commands(_ data: Data, event: String = "Stop") throws -> [String] {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = document["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func testCustomizedLegacyCommandsSurviveConnectAndDisconnect() throws {
        for agent in CodingAgent.allCases {
            let original = legacy(agent)
            let customized = [
                original + "; echo user-maintenance",
                original + " && echo user-maintenance",
                original + " || echo user-failure-handler",
                original + "\necho user-maintenance",
                original + " # user annotation",
                original.replacingOccurrences(of: " || exit 0; ", with: " || echo user-failure-handler; "),
                "/usr/bin/pgrep -xq Backlit && echo " + AgentBridge.shellArgument(original)
            ]
            for command in customized {
                let source = try configuration(command: command)
                for enabled in [false, true] {
                    let result = try AgentBridge.merged(source, agent: agent, enabled: enabled,
                        binary: newBinary, priorBinaries: [oldBinary])
                    XCTAssertTrue(try commands(result).contains(command), "Custom command lost: \(command)")
                    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
                    let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
                    let groups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
                    XCTAssertEqual(groups.first?["matcher"] as? String, "user-matcher")
                    let retained = try XCTUnwrap(groups.first?["hooks"] as? [[String: Any]])
                    XCTAssertEqual(retained.first?["timeout"] as? Int, 17)
                    XCTAssertTrue(try commands(result).contains("echo another-user-hook"))
                }
            }
        }
    }

    func testExactKnownLegacyCommandsStillMigrateAcrossAgentsAndPhases() throws {
        for agent in CodingAgent.allCases {
            for phase in ["working", "waiting", "attention", "ended"] {
                let original = legacy(agent, phase: phase)
                let source = try configuration(command: original)
                for enabled in [false, true] {
                    let result = try AgentBridge.merged(source, agent: agent, enabled: enabled,
                        binary: newBinary, priorBinaries: [oldBinary])
                    XCTAssertFalse(try commands(result).contains(original))
                    XCTAssertTrue(try commands(result).contains("echo another-user-hook"))
                    XCTAssertEqual(try commands(result).contains(AgentBridge.command(agent, "waiting", binary: newBinary)), enabled)
                }
            }
        }
    }

    func testUnknownLegacyPhaseBinaryAndOtherAgentAreNotAssumedOwned() throws {
        for agent in CodingAgent.allCases {
            let otherAgent: CodingAgent = agent == .claude ? .codex : .claude
            for original in [legacy(agent, phase: "custom-phase"),
                             legacy(agent, binary: "/unrecognized/Backlit"),
                             legacy(otherAgent)] {
                let source = try configuration(command: original)
                for enabled in [false, true] {
                    let result = try AgentBridge.merged(source, agent: agent, enabled: enabled,
                        binary: newBinary, priorBinaries: [oldBinary])
                    XCTAssertTrue(try commands(result).contains(original))
                }
            }
        }
    }
}
