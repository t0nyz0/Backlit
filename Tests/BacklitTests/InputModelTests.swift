import XCTest
@testable import Backlit

@MainActor final class InputModelTests: XCTestCase {
    private func fixture(_ test: (AppModel) -> Void) {
        let suite = "local.backlit.test.input-model." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(demo: true, defaults: defaults)
        defer {
            model.typingDriver = nil
            XCTAssertTrue(model.prepareQuit())
            defaults.removePersistentDomain(forName: suite)
        }
        model.brightness = 0.8
        test(model)
    }

    func testContactTypingAndBlinkReachProductionEffectOutput() {
        fixture { model in
            model.mode = .touch
            for contact in [false, true] {
                for typing in [false, true] {
                    for blinking in [false, true] {
                        model.touchDown = contact
                        model.setPreviewInput(typing: typing, blinking: blinking, away: false)
                        let expected = (contact && !blinking) || typing
                        XCTAssertEqual(model.effectOutput(at: 0), expected ? 0.8 : 0,
                                       "contact=\(contact), typing=\(typing), blink=\(blinking)")
                    }
                }
            }
            model.enabled = false
            model.setPreviewInput(typing: true, blinking: false, away: false)
            XCTAssertEqual(model.effectOutput(at: 0), 0)
            model.enabled = true
            model.setPreviewInput(typing: true, blinking: false, away: false)
            model.pausedReason = "Synthetic session pause"
            XCTAssertEqual(model.effectOutput(at: 0), 0)
        }
    }

    func testEveryAgentStateAndAwayFlagReachProductionEffectOutput() {
        fixture { model in
            model.mode = .agents
            for state in [AgentState.waiting, .working, .attention] {
                model.agents = [.init(agent: .codex, state: state, time: Date())]
                for away in [false, true] {
                    model.setPreviewInput(typing: false, blinking: false, away: away)
                    let factor: Double = state == .waiting ? 0.18 : state == .working ? 0.15 : away ? 1 : 0.5
                    XCTAssertEqual(model.effectOutput(at: 0), 0.8 * factor, accuracy: 0.000001,
                                   "state=\(state), away=\(away)")
                }
            }
        }
    }

    func testStandaloneTypingIgnoresTrackpadContactsAndLegacyToggle() {
        fixture { model in
            model.mode = .typing
            model.controlWanted = true
            XCTAssertTrue(model.availableModes.contains(.typing))
            for legacyToggle in [false, true] {
                model.typingEnabled = legacyToggle
                XCTAssertTrue(model.typingInputEligible)
                for contact in [false, true] {
                    model.touchDown = contact
                    for typing in [false, true] {
                        model.setPreviewInput(typing: typing, blinking: false, away: false)
                        XCTAssertEqual(model.effectOutput(at: 0), typing ? 0.8 : 0)
                    }
                }
            }
            model.setPreviewInput(typing: false, blinking: false, away: false)
            XCTAssertEqual(model.effectOutput(at: 0), 0)
            model.mode = .touch
            model.typingEnabled = false
            XCTAssertFalse(model.typingInputEligible)
            model.typingEnabled = true
            XCTAssertTrue(model.typingInputEligible)
            model.mode = .typing
            model.keepClosed = true
            model.setPreviewInputSession(lidClosed: true, screenAsleep: true)
            XCTAssertTrue(model.typingInputEligible)
            model.setPreviewInputSession(lidClosed: true, locked: true, screenAsleep: true)
            XCTAssertFalse(model.typingInputEligible)
        }
    }

    func testStandaloneTypingPersistsWithoutEnablingTrackpadTypingOption() {
        let suite = "local.backlit.test.typing-mode." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "typing.enabled")
        let model = AppModel(demo: true, defaults: defaults)
        model.mode = .typing
        XCTAssertEqual(defaults.string(forKey: "mode"), "typing")
        XCTAssertEqual(model.mode, .typing)
        XCTAssertFalse(model.typingEnabled)
        XCTAssertTrue(model.availableModes.contains(.typing))
        XCTAssertEqual(GlowMode.typing.title, "Typing")
        XCTAssertTrue(model.prepareQuit())
        let reopened = AppModel(demo: true, defaults: defaults)
        XCTAssertEqual(reopened.mode, .typing)
        XCTAssertFalse(reopened.typingEnabled)
        XCTAssertTrue(reopened.prepareQuit())
    }

    func testPermissionGainRetriesOnceWithoutStartingOnEveryFrame() {
        fixture { model in
            var eligible = true, permission = false, running = false
            var now = 0.0, starts = 0, checks = 0, stops = 0
            model.typingDriver = TypingDriver(eligible: { eligible }, permission: {
                checks += 1; return permission
            }, running: { running }, start: {
                starts += 1; running = permission; return running
            }, stop: { stops += 1; running = false }, now: { now })
            model.synchronizeTyping()
            XCTAssertEqual(starts, 1)
            for _ in 0..<100 { model.synchronizeTyping() }
            XCTAssertEqual(starts, 1); XCTAssertEqual(checks, 1)
            permission = true; now = 0.9
            model.synchronizeTyping()
            XCTAssertEqual(starts, 1)
            now = 1
            model.synchronizeTyping()
            XCTAssertEqual(starts, 2); XCTAssertTrue(running)
            for tick in 2...20 { now = Double(tick); model.synchronizeTyping() }
            XCTAssertEqual(starts, 2)
            // A stopped tap with unchanged access must not cause a retry loop.
            running = false; now = 21
            model.synchronizeTyping()
            XCTAssertEqual(starts, 2)
            model.synchronizeTyping(forceRestart: true)
            XCTAssertEqual(starts, 3)
            eligible = false
            model.synchronizeTyping()
            XCTAssertEqual(stops, 1)
            eligible = true
            model.synchronizeTyping()
            XCTAssertEqual(starts, 4)
            permission = false; now = 22
            model.synchronizeTyping()
            permission = true; now = 23
            model.synchronizeTyping()
            XCTAssertEqual(starts, 5)
        }
    }

    func testObservedPermissionRevocationStopsTapAndClearsActiveBurstOnce() {
        fixture { model in
            model.mode = .touch
            var permission = true, running = false
            var now = 0.0, starts = 0, stops = 0, checks = 0
            model.typingDriver = TypingDriver(eligible: { true }, permission: {
                checks += 1; return permission
            }, running: { running }, start: {
                starts += 1; running = permission; return running
            }, stop: { stops += 1; running = false }, now: { now })
            model.synchronizeTyping()
            model.setPreviewInput(typing: true, blinking: false, away: false)
            XCTAssertEqual(model.effectOutput(at: 0), 0.8)
            permission = false; now = 1
            model.synchronizeTyping()
            XCTAssertFalse(running)
            XCTAssertEqual(stops, 1)
            XCTAssertEqual(model.effectOutput(at: 0), 0)
            XCTAssertEqual(model.typingStatus, "Input Monitoring permission is required for typing response")
            for _ in 0..<100 { model.synchronizeTyping() }
            XCTAssertEqual(checks, 2); XCTAssertEqual(stops, 1); XCTAssertEqual(starts, 1)
            now = 2
            model.synchronizeTyping()
            XCTAssertEqual(stops, 1); XCTAssertEqual(starts, 1)
            permission = true; now = 3
            model.synchronizeTyping()
            XCTAssertEqual(starts, 2); XCTAssertTrue(running)
            XCTAssertEqual(model.effectOutput(at: 0), 0)
        }
    }

    func testClosedDisplayInputEligibilityUsesConfirmedOverrideAndSessionSafety() {
        fixture { model in
            model.mode = .touch
            model.controlWanted = true
            for closed in [false, true] {
                for override in [false, true] {
                    for screenAsleep in [false, true] {
                        for locked in [false, true] {
                            for systemAsleep in [false, true] {
                                for active in [false, true] {
                                    model.keepClosed = override
                                    model.setPreviewInputSession(lidClosed: closed, locked: locked,
                                        screenAsleep: screenAsleep, systemAsleep: systemAsleep,
                                        sessionActive: active)
                                    let expected = !locked && !systemAsleep && active &&
                                        (!screenAsleep || (closed && override))
                                    XCTAssertEqual(model.inputSessionEligible, expected,
                                        "closed=\(closed), override=\(override), screen=\(screenAsleep), locked=\(locked), sleep=\(systemAsleep), active=\(active)")
                                }
                            }
                        }
                    }
                }
            }
            model.keepClosed = true
            model.setPreviewInputSession(lidClosed: true, screenAsleep: true)
            XCTAssertTrue(model.inputSessionEligible)
            model.controlWanted = false
            XCTAssertFalse(model.inputSessionEligible)
            model.controlWanted = true
            model.enabled = false
            XCTAssertFalse(model.inputSessionEligible)
            model.enabled = true
            model.pausedReason = "Synthetic pause"
            XCTAssertFalse(model.inputSessionEligible)
            model.pausedReason = nil
            model.mode = .steady
            XCTAssertFalse(model.inputSessionEligible)
            model.mode = .touch
            XCTAssertTrue(model.inputSessionEligible)
            model.withHardwareRecovery {
                XCTAssertFalse(model.inputSessionEligible)
            }
        }
    }
}
