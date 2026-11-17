import XCTest
@testable import Backlit

final class BridgeConnectionSetupTests: XCTestCase {
    private struct Read: Equatable { let account: String; let create: Bool; let interactive: Bool }
    private enum Unavailable: Error { case key, listener }

    func testAutomaticHAResumeReadsWithoutPromptOrCreation() throws {
        var reads: [Read] = []
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .off,
            intent: .automaticResume, readToken: { account, create, interactive in
                reads.append(Read(account: account, create: create, interactive: interactive)); return "fixture-ha-key"
            })
        XCTAssertEqual(reads, [.init(account: BridgeToken.account, create: false, interactive: false)])
        var started = false
        try plan.start(lan: true) { lan, home, agent, access in
            started = true; XCTAssertTrue(lan); XCTAssertNotNil(home); XCTAssertNil(agent); XCTAssertEqual(access, .off)
        }
        XCTAssertTrue(started)
    }
    func testExplicitHASetupRetainsDeliberateAuthorizationAndCreation() throws {
        var reads: [Read] = []
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .off,
            intent: .deliberateSetup, readToken: { account, create, interactive in
                reads.append(Read(account: account, create: create, interactive: interactive)); return "fixture-created-ha"
            })
        XCTAssertEqual(reads, [.init(account: BridgeToken.account, create: true, interactive: true)])
        XCTAssertTrue(plan.homeAssistantEnabled); XCTAssertTrue(plan.errors.isEmpty)
    }
    func testMCPResumeSurvivesUnavailableHAKeyAndCannotInheritLANSharing() throws {
        var reads: [Read] = []
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .control,
            intent: .automaticResume, readToken: { account, create, interactive in
                reads.append(Read(account: account, create: create, interactive: interactive))
                if account == BridgeToken.account { throw Unavailable.key }
                return "fixture-agent-key"
            })
        XCTAssertEqual(reads, [.init(account: BridgeToken.agentAccount, create: false, interactive: false),
                               .init(account: BridgeToken.account, create: false, interactive: false)])
        XCTAssertFalse(plan.homeAssistantEnabled); XCTAssertEqual(plan.agentAccess, .control)
        XCTAssertTrue(plan.errors.contains { $0.contains("Home Assistant") && $0.contains("Connections") })
        var starts = 0
        try plan.start(lan: true) { lan, home, agent, access in
            starts += 1; XCTAssertFalse(lan); XCTAssertNil(home); XCTAssertNotNil(agent); XCTAssertEqual(access, .control)
        }
        XCTAssertEqual(starts, 1)
    }
    func testMissingHAKeyIsNotCreatedDuringResumeAndNoListenerStarts() throws {
        var creates = 0
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .off,
            intent: .automaticResume, readToken: { _, create, _ in
                if create { creates += 1; return "fixture-new-key" }
                throw Unavailable.key
            })
        var starts = 0
        let started = try plan.start(lan: true) { _, _, _, _ in starts += 1 }
        XCTAssertEqual(creates, 0); XCTAssertFalse(started); XCTAssertEqual(starts, 0)
        XCTAssertFalse(plan.homeAssistantEnabled); XCTAssertEqual(plan.errors.count, 1)
    }
    func testBothCredentialsUnavailableStartsNothingAndKeepsScopeSpecificErrors() throws {
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .status,
            intent: .automaticResume, readToken: { _, _, _ in throw Unavailable.key })
        var starts = 0
        XCTAssertFalse(try plan.start(lan: true) { _, _, _, _ in starts += 1 })
        XCTAssertEqual(starts, 0); XCTAssertFalse(plan.homeAssistantEnabled); XCTAssertEqual(plan.agentAccess, .off)
        XCTAssertEqual(plan.errors.count, 2)
    }
    func testMCPKeyFailureDoesNotDisableHealthyHA() throws {
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .control,
            intent: .automaticResume, readToken: { account, _, _ in
                if account == BridgeToken.agentAccount { throw Unavailable.key }
                return "fixture-ha-key"
            })
        XCTAssertTrue(plan.homeAssistantEnabled); XCTAssertEqual(plan.agentAccess, .off)
        try plan.start(lan: true) { lan, home, agent, access in
            XCTAssertTrue(lan); XCTAssertNotNil(home); XCTAssertNil(agent); XCTAssertEqual(access, .off)
        }
    }
    func testMCPOnlySetupNeverReadsOrCreatesAnHAKey() throws {
        var reads: [Read] = []
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: false, agentAccess: .status,
            intent: .deliberateSetup, readToken: { account, create, interactive in
                reads.append(.init(account: account, create: create, interactive: interactive)); return "fixture-agent-key"
            })
        XCTAssertEqual(reads, [.init(account: BridgeToken.agentAccount, create: false, interactive: false)])
        try plan.start(lan: true) { lan, home, agent, access in
            XCTAssertFalse(lan); XCTAssertNil(home); XCTAssertNotNil(agent); XCTAssertEqual(access, .status)
        }
    }
    func testListenerFailureStillPropagatesRatherThanReportingConnectionSuccess() throws {
        let plan = try BridgeConnectionSetup.prepare(homeAssistantRequested: true, agentAccess: .control,
            intent: .deliberateSetup, readToken: { _, _, _ in "fixture-key" })
        XCTAssertThrowsError(try plan.start(lan: true) { _, _, _, _ in throw Unavailable.listener })
    }
}
