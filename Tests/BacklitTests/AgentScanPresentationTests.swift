import XCTest
@testable import Backlit

@MainActor final class AgentScanPresentationTests: XCTestCase {
    private func fixture(_ body: (AppModel) throws -> Void) rethrows {
        let suite = "local.backlit.test.scan-presentation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(demo: true, defaults: defaults)
        defer { XCTAssertTrue(model.prepareQuit()); defaults.removePersistentDomain(forName: suite) }
        try body(model)
    }
    func testEmptyLimitedSnapshotDoesNotClaimNoRecentSignals() {
        fixture { model in
            model.applyAgentScan(.init(events: [], limited: true))
            XCTAssertTrue(model.agentMetadataLimited)
            XCTAssertNotNil(model.agentMetadataWarning)
            XCTAssertEqual(model.apiState()["agent_state"] as? String, "scan_limited")
            XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, true)
            XCTAssertEqual(model.agentLightState().agentScanLimited, true)
        }
    }
    func testObservedEventsRemainSortedAndExplicitlyPartialThenRecover() {
        fixture { model in
            let older = AgentEvent(agent: .codex, state: .working, time: Date(timeIntervalSince1970: 10))
            let newer = AgentEvent(agent: .claude, state: .attention, time: Date(timeIntervalSince1970: 20))
            model.applyAgentScan(.init(events: [newer, older], limited: true))
            XCTAssertEqual(model.agents, [older, newer])
            XCTAssertEqual(model.agentState, .attention)
            XCTAssertEqual(model.apiState()["agent_state"] as? String, "attention")
            XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, true)
            model.applyAgentScan(.init(events: [], limited: false))
            XCTAssertFalse(model.agentMetadataLimited)
            XCTAssertNil(model.agentMetadataWarning)
            XCTAssertEqual(model.apiState()["agent_state"] as? String, "no_recent_signals")
            XCTAssertEqual(model.agentLightState().agentScanLimited, false)
        }
    }
    func testMCPPartialFlagRoundTripsAndOlderBackendsRemainDecodable() throws {
        try fixture { model in
            model.applyAgentScan(.init(events: [], limited: true))
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let encoded = try encoder.encode(model.agentLightState())
            XCTAssertEqual(try decoder.decode(AgentLightState.self, from: encoded).agentScanLimited, true)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            legacy.removeValue(forKey: "agent_scan_limited")
            let old = try decoder.decode(AgentLightState.self, from: JSONSerialization.data(withJSONObject: legacy))
            XCTAssertNil(old.agentScanLimited)
        }
    }
}
