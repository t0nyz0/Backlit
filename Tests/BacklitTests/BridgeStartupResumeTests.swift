import XCTest
@testable import Backlit

final class BridgeStartupResumeTests: XCTestCase {
    @MainActor func testStalledReadDoesNotHoldMainActor() async {
        let started = expectation(description: "background read began")
        let applied = expectation(description: "result applied")
        let release = DispatchSemaphore(value: 0)
        let resume = BridgeStartupResume()
        resume.begin(enabled: true, access: .off, lan: false, prepare: { enabled, access in
            XCTAssertFalse(Thread.isMainThread)
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return try BridgeConnectionSetup.prepare(homeAssistantRequested: enabled, agentAccess: access,
                       intent: .automaticResume, readToken: { _, create, interactive in
                XCTAssertFalse(create)
                XCTAssertFalse(interactive)
                return "fixture"
            })
        }, complete: { result, lan in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get().homeToken, "fixture")
            XCTAssertFalse(lan)
            applied.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)
        release.signal()
        await fulfillment(of: [applied], timeout: 2)
    }

    @MainActor func testSupersededReadDoesNotApply() async {
        let started = expectation(description: "stale read began")
        let released = expectation(description: "stale read released")
        let stale = expectation(description: "stale result must not apply")
        stale.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let resume = BridgeStartupResume()
        resume.begin(enabled: true, access: .off, lan: true, prepare: { enabled, access in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            released.fulfill()
            return try BridgeConnectionSetup.prepare(homeAssistantRequested: enabled, agentAccess: access,
                       intent: .automaticResume, readToken: { _, _, _ in "stale fixture" })
        }, complete: { _, _ in stale.fulfill() })
        await fulfillment(of: [started], timeout: 2)
        resume.invalidate()
        XCTAssertFalse(resume.isPending)
        XCTAssertFalse(resume.updateLAN(false))
        release.signal()
        await fulfillment(of: [released], timeout: 2)
        await fulfillment(of: [stale], timeout: 0.25)
    }

    @MainActor func testLANEditsKeepOnePendingHomeAssistantReadAndUseLatestScope() async {
        let started = expectation(description: "Home Assistant key read began")
        let applied = expectation(description: "latest local-only intent applied")
        let release = DispatchSemaphore(value: 0)
        let resume = BridgeStartupResume()
        resume.begin(enabled: true, access: .off, lan: true, prepare: { enabled, access in
            try BridgeConnectionSetup.prepare(homeAssistantRequested: enabled, agentAccess: access,
                       intent: .automaticResume, readToken: { account, create, interactive in
                XCTAssertEqual(account, BridgeToken.account)
                XCTAssertFalse(create)
                XCTAssertFalse(interactive)
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
                return "home fixture"
            })
        }, complete: { result, lan in
            XCTAssertFalse(resume.isPending)
            XCTAssertTrue((try? result.get().homeAssistantEnabled) == true)
            XCTAssertTrue((try? result.get().start(lan: lan) { bindLAN, home, agent, access in
                XCTAssertFalse(bindLAN)
                XCTAssertEqual(home, "home fixture")
                XCTAssertNil(agent)
                XCTAssertEqual(access, .off)
            }) == true)
            applied.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(resume.isPending)
        XCTAssertTrue(resume.updateLAN(false))
        XCTAssertTrue(resume.updateLAN(true))
        XCTAssertTrue(resume.updateLAN(false))
        release.signal()
        await fulfillment(of: [applied], timeout: 2)
    }

    @MainActor func testOffSupersedesPendingHomeAssistantWithMCPOnly() async {
        let started = expectation(description: "old Home Assistant read began")
        let stale = expectation(description: "old result never binds")
        stale.isInverted = true
        let applied = expectation(description: "only MCP remains enabled")
        let release = DispatchSemaphore(value: 0)
        let resume = BridgeStartupResume()
        resume.begin(enabled: true, access: .off, lan: true, prepare: { enabled, access in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return try BridgeConnectionSetup.prepare(homeAssistantRequested: enabled, agentAccess: access,
                       intent: .automaticResume, readToken: { _, _, _ in "old home fixture" })
        }, complete: { _, _ in stale.fulfill() })
        await fulfillment(of: [started], timeout: 2)
        resume.invalidate()
        resume.begin(enabled: false, access: .status, lan: true, prepare: { enabled, access in
            try BridgeConnectionSetup.prepare(homeAssistantRequested: enabled, agentAccess: access,
                       intent: .automaticResume, readToken: { account, create, interactive in
                XCTAssertEqual(account, BridgeToken.agentAccount)
                XCTAssertFalse(create)
                XCTAssertFalse(interactive)
                return "agent fixture"
            })
        }, complete: { result, lan in
            XCTAssertTrue((try? result.get().start(lan: lan) { bindLAN, home, agent, access in
                XCTAssertFalse(bindLAN)
                XCTAssertNil(home)
                XCTAssertEqual(agent, "agent fixture")
                XCTAssertEqual(access, .status)
            }) == true)
            applied.fulfill()
        })
        release.signal()
        await fulfillment(of: [applied], timeout: 2)
        await fulfillment(of: [stale], timeout: 0.25)
    }
}
