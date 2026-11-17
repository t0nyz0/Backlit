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
    private func event(_ state: AgentState, at time: Double = 10) -> AgentEvent {
        .init(agent: .codex, state: state, time: Date(timeIntervalSince1970: time))
    }
    func testCompleteEmptySessionPresentationPreservesExistingUX() {
        fixture { model in
            model.applyAgentScan(.init(events: [], limited: false))
            let status = model.agentSessionStatus
            XCTAssertEqual(status.menuSummary, "Waiting for an agent")
            XCTAssertEqual(status.workspaceSummary, "Waiting for an agent")
            XCTAssertNil(status.warning)
            XCTAssertEqual(model.apiState()["agent_state"] as? String, "no_recent_signals")
            XCTAssertEqual(model.apiState()["agent_sessions"] as? Int, 0)
            XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, false)
        }
    }
    func testCompleteNonemptyPresentationPreservesAllObservedStates() {
        fixture { model in
            for state in [AgentState.waiting, .working, .attention] {
                model.applyAgentScan(.init(events: [event(state), event(state, at: 20)], limited: false))
                let status = model.agentSessionStatus
                XCTAssertEqual(status.menuSummary, state.rawValue.capitalized)
                XCTAssertEqual(status.workspaceSummary, "2 sessions · \(state.rawValue)")
                XCTAssertNil(status.warning)
                XCTAssertEqual(model.apiState()["agent_state"] as? String, state.rawValue)
                XCTAssertEqual(model.apiState()["agent_sessions"] as? Int, 2)
                XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, false)
            }
        }
    }
    func testPartialEmptyPresentationNeverClaimsWaitingOrAnExactZero() {
        fixture { model in
            model.applyAgentScan(.init(events: [], limited: true))
            let status = model.agentSessionStatus
            XCTAssertEqual(status.menuSummary, "Session snapshot incomplete")
            XCTAssertEqual(status.workspaceSummary, status.menuSummary)
            XCTAssertNotNil(status.warning)
            XCTAssertEqual(status.observedCount, 0)
            XCTAssertEqual(model.apiState()["agent_state"] as? String, "scan_limited")
            XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, true)
        }
    }
    func testPartialNonemptyPresentationQualifiesCountsAndEveryState() {
        fixture { model in
            for state in [AgentState.waiting, .working, .attention] {
                for count in [1, 2] {
                    model.applyAgentScan(.init(events: (0..<count).map { event(state, at: Double($0)) }, limited: true))
                    let status = model.agentSessionStatus
                    let noun = count == 1 ? "session" : "sessions"
                    XCTAssertEqual(status.menuSummary, "\(count) observed \(noun) · \(state.rawValue)")
                    XCTAssertEqual(status.workspaceSummary, status.menuSummary)
                    XCTAssertNotNil(status.warning)
                    XCTAssertEqual(model.apiState()["agent_state"] as? String, state.rawValue)
                    XCTAssertEqual(model.apiState()["agent_sessions"] as? Int, count)
                    XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, true)
                    XCTAssertEqual(model.agentLightState().agentScanLimited, true)
                }
            }
        }
    }
    func testRecoveryClearsWarningAndDoesNotRetainPartialCountsOrState() {
        fixture { model in
            let transitions: [([AgentEvent], Bool)] = [([], true), ([event(.attention)], true),
                ([event(.working), event(.waiting, at: 20)], false), ([], false), ([event(.waiting)], true), ([], false)]
            for (events, incomplete) in transitions {
                model.applyAgentScan(.init(events: events, limited: incomplete))
                let status = model.agentSessionStatus
                XCTAssertEqual(status.observedCount, events.count)
                XCTAssertEqual(status.incomplete, incomplete)
                XCTAssertEqual(status.warning != nil, incomplete)
                XCTAssertEqual(model.agentMetadataWarning, status.warning)
                XCTAssertEqual(model.apiState()["agent_scan_limited"] as? Bool, incomplete)
                XCTAssertEqual(model.apiState()["agent_sessions"] as? Int, events.count)
                if !incomplete {
                    XCTAssertFalse(status.menuSummary.contains("observed"))
                    XCTAssertFalse(status.workspaceSummary.contains("observed"))
                    XCTAssertNil(status.warning)
                } else if events.isEmpty {
                    XCTAssertEqual(status.menuSummary, "Session snapshot incomplete")
                }
            }
        }
    }

}
