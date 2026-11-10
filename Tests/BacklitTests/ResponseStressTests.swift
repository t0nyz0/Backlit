import XCTest
@testable import Backlit

/// Deterministic stress, using scalar fixtures only: no devices, timers or I/O.
final class ResponseStressTests: XCTestCase {
    private struct Generator {
        private var state: UInt64 = 0x92C4_13A7_B8D0_6E51
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        mutating func index(_ count: Int) -> Int { Int((next() >> 32) % UInt64(count)) }
        mutating func unit() -> Double { Double(next() >> 11) / 9_007_199_254_740_992 }
        mutating func bit() -> Bool { next() & (1 << 47) != 0 }
        mutating func adversarial() -> Double {
            let edges: [Double] = [.nan, .infinity, -.infinity, -.greatestFiniteMagnitude,
                                   .greatestFiniteMagnitude, -.leastNonzeroMagnitude,
                                   .leastNonzeroMagnitude, -1, 0, 0.008, 0.5, 1, 2]
            return index(3) == 0 ? edges[index(edges.count)] : unit() * 4 - 1
        }
    }

    func testSeededResponseSequenceAlwaysRespectsFiniteBrightnessCeiling() {
        var generator = Generator(), battery = BatteryResponse(), music = MusicResponse()
        var clock = 0.0
        for frame in 0..<6_000 {
            clock += 0.001 + generator.unit() * 0.15
            if frame % 131 == 0 { clock += 31 }
            if frame % 277 == 0 { clock = generator.unit() }
            let suppliedTime = frame % 53 == 0 ? generator.adversarial() : clock
            var options = BatteryResponseOptions()
            options.chargingStyle = BatteryChargeStyle.allCases[generator.index(BatteryChargeStyle.allCases.count)]
            options.readyStyle = BatteryReadyStyle.allCases[generator.index(BatteryReadyStyle.allCases.count)]
            options.readyEnabled = generator.bit()
            options.readyDuration = generator.adversarial()
            options.readyThreshold = generator.adversarial()
            let multiplier = battery.update(charge: generator.adversarial(), externalPower: generator.bit(), at: suppliedTime, options: options)
            let envelope = music.update(energy: generator.adversarial(), at: suppliedTime, automatic: generator.bit(), preset: MusicResponsePreset.allCases[generator.index(MusicResponsePreset.allCases.count)])
            XCTAssertTrue(multiplier.isFinite && (0...1).contains(multiplier), "battery frame \(frame)")
            XCTAssertTrue(envelope.isFinite && (0...1).contains(envelope), "music frame \(frame)")
            XCTAssertTrue(music.adaptiveGain.isFinite && (0.75...12.5).contains(music.adaptiveGain))
            var input = EffectInput()
            input.enabled = generator.bit()
            input.brightness = generator.adversarial()
            input.battery = multiplier
            input.audio = envelope
            input.intensity = generator.adversarial()
            input.period = generator.adversarial()
            input.signalLevel = generator.adversarial()
            input.strobe = generator.bit()
            input.touchDown = generator.bit()
            input.away = generator.bit()
            input.agent = [.waiting, .working, .attention][generator.index(3)]
            for mode in GlowMode.allCases {
                input.mode = mode
                let result = Effects.level(at: suppliedTime, input: input)
                XCTAssertTrue(result.isFinite && result >= 0 && result <= (mode == .battery ? 1 : Effects.clamp(input.brightness)), "\(mode) frame \(frame)")
                if !input.enabled { XCTAssertEqual(result, 0) }
            }
        }
    }

    func testLongChargingSessionsDoNotRepeatReadyCueFromThresholdJitter() {
        for style in BatteryReadyStyle.allCases {
            var response = BatteryResponse(), options = BatteryResponseOptions()
            options.readyEnabled = true; options.readyThreshold = 0.8
            options.readyDuration = 2; options.readyStyle = style
            for cycle in 0..<30 {
                let start = Double(cycle) * 20
                _ = response.update(charge: 0.7, externalPower: true, at: start, options: options)
                _ = response.update(charge: 0.8, externalPower: true, at: start + 1, options: options)
                XCTAssertTrue(response.completionActive)
                for frame in 1...160 {
                    let elapsed = Double(frame) / 20
                    let jitteredCharge = frame % 2 == 0 ? 0.79 : 0.81
                    let value = response.update(charge: jitteredCharge, externalPower: true, at: start + 1 + elapsed, options: options)
                    XCTAssertTrue(value.isFinite && (0...1).contains(value))
                    if elapsed >= options.readyDuration {
                        XCTAssertFalse(response.completionActive, "Threshold jitter repeated cue in cycle \(cycle)")
                    }
                }
                _ = response.update(charge: 0.8, externalPower: false, at: start + 10, options: options)
                XCTAssertFalse(response.ready)
                _ = response.update(charge: 0.8, externalPower: true, at: start + 11, options: options)
                XCTAssertTrue(response.completionActive, "Observed replug can produce a new ready cue")
                options.readyEnabled = false
                _ = response.update(charge: 0.8, externalPower: true, at: start + 11.1, options: options)
                XCTAssertFalse(response.completionActive)
                options.readyEnabled = true
                _ = response.update(charge: 0.8, externalPower: true, at: start + 11.2, options: options)
                XCTAssertFalse(response.completionActive, "Re-enabling an option is not a new charge completion")
            }
        }
    }

    func testMusicReleaseCatchesUpAfterDroppedFramesBeforeStaleCutoff() {
        for preset in MusicResponsePreset.allCases {
            for automatic in [false, true] {
                for gap in [0.3, 0.5, 0.75] {
                    var uninterrupted = MusicResponse(), delayed = MusicResponse()
                    let peak = delayed.update(energy: 0.8, at: 0, automatic: automatic, preset: preset)
                    XCTAssertEqual(uninterrupted.update(energy: 0.8, at: 0, automatic: automatic, preset: preset), peak)
                    let frames = 100
                    var expected = 0.0
                    for frame in 1...frames {
                        expected = uninterrupted.update(energy: 0, at: gap * Double(frame) / Double(frames), automatic: automatic, preset: preset)
                    }
                    let caughtUp = delayed.update(energy: 0, at: gap, automatic: automatic, preset: preset)
                    XCTAssertEqual(caughtUp, expected, accuracy: 0.000_000_1, "\(preset), automatic=\(automatic), gap=\(gap)")
                }
            }
        }
    }

    func testMusicReleaseIsConsistentAcrossTimerRatesAndEventuallySilent() {
        for preset in MusicResponsePreset.allCases {
            var endLevels: [Double] = []
            for rate in [10, 20, 120] {
                var response = MusicResponse()
                for frame in 0...rate {
                    _ = response.update(energy: 0.4, at: Double(frame) / Double(rate), automatic: true, preset: preset)
                }
                var released = 0.0
                for frame in 1...(rate / 2) {
                    released = response.update(energy: 0, at: 1 + Double(frame) / Double(rate), automatic: true, preset: preset)
                }
                endLevels.append(released)
                for frame in (rate / 2 + 1)...(rate * 5) {
                    released = response.update(energy: 0.005, at: 1 + Double(frame) / Double(rate), automatic: true, preset: preset)
                }
                XCTAssertEqual(released, 0, "Quiet background noise must not sustain a glow")
            }
            XCTAssertEqual(endLevels[0], endLevels[1], accuracy: 0.000_000_1)
            XCTAssertEqual(endLevels[1], endLevels[2], accuracy: 0.000_000_1)
        }
    }

    func testSignalStormStaysBoundedAndCannotResetOrClearLocalFocus() throws {
        var generator = Generator(), engine = ActivitySignalEngine()
        let local = try ActivitySignal(category: .focus, state: .active, duration: 60)
        engine.submit(local, at: 0, source: .local)
        var previousLocalLevel = 0.0
        for index in 0..<1_000 {
            let time = Double(index) / 20
            let category = ActivityCategory.allCases[generator.index(ActivityCategory.allCases.count)]
            let state = ActivityState.allCases[generator.index(ActivityState.allCases.count)]
            let duration = state == .clear ? nil : 1 + generator.unit() * 30
            let signal = try ActivitySignal(category: category, state: state, duration: duration)
            engine.submit(signal, at: time)
            let value = engine.level(at: time)
            XCTAssertTrue(value.isFinite && (0...1).contains(value))
            XCTAssertLessThanOrEqual(engine.count, 12)
            if index % 7 == 0 {
                engine.clearExternal()
                let currentLocalLevel = engine.level(at: time)
                XCTAssertEqual(engine.current, local)
                XCTAssertEqual(engine.count, 1)
                XCTAssertGreaterThanOrEqual(currentLocalLevel, previousLocalLevel)
                previousLocalLevel = currentLocalLevel
            }
        }
        engine.clearExternal()
        _ = engine.level(at: 60)
        XCTAssertEqual(engine.current?.state, .complete)
        XCTAssertTrue(engine.requiresAnimation)
        XCTAssertEqual(engine.level(at: 68), 0)
        XCTAssertEqual(engine.count, 0)
    }

    func testTypingBurstsRemainBoundedAfterThousandsOfResetsAndStaleDeadlines() {
        var generator = Generator(), activity = TypingActivity()
        var time = 0.0
        for index in 0..<4_000 {
            if index % 59 == 0 {
                activity.reset()
                XCTAssertFalse(activity.active)
                XCTAssertNil(activity.deadline)
            }
            activity.holdDuration = generator.adversarial()
            XCTAssertTrue((0.08...0.6).contains(activity.holdDuration))
            time += 0.01 + generator.unit() * 0.05
            _ = activity.keyDown(at: time)
            XCTAssertTrue(activity.active)
            let deadline = activity.deadline!
            XCTAssertTrue(deadline.isFinite && deadline > time && deadline - time <= 0.600_000_1)
            XCTAssertFalse(activity.expire(at: time))
            XCTAssertFalse(activity.keyDown(at: time - 1))
            XCTAssertEqual(activity.deadline, deadline)
            XCTAssertFalse(activity.keyDown(at: .nan))
            XCTAssertEqual(activity.deadline, deadline)
            if index % 5 == 0 {
                XCTAssertTrue(activity.expire(at: deadline))
                XCTAssertFalse(activity.active)
                XCTAssertNil(activity.deadline)
                XCTAssertFalse(activity.expire(at: deadline + 10))
            }
        }
        XCTAssertTrue(activity.active)
        XCTAssertTrue(activity.expire(at: time + 1))
        XCTAssertFalse(activity.active)
    }

    func testStatusGeometryIsMonotonicAndContainedForShuffledOutput() {
        var generator = Generator()
        var levels = (0..<4_000).map { _ in generator.unit() }
        levels.append(contentsOf: [0, .leastNonzeroMagnitude, 0.01, 0.5, 0.99, 1])
        levels.sort()
        var previousStep = 0, previousWidth: CGFloat = 0
        for level in levels {
            let step = StatusIconGeometry.step(for: level)
            XCTAssertGreaterThanOrEqual(step, previousStep)
            previousStep = step
            if level == 0 {
                XCTAssertNil(StatusIconGeometry.marker(at: step))
            } else {
                let marker = StatusIconGeometry.marker(at: step)!
                XCTAssertGreaterThanOrEqual(marker.width, 1.8)
                XCTAssertGreaterThanOrEqual(marker.width, previousWidth)
                XCTAssertTrue(StatusIconGeometry.interior.insetBy(dx: -0.000_001, dy: -0.000_001).contains(marker))
                previousWidth = marker.width
            }
        }
        XCTAssertEqual(StatusIconGeometry.marker(at: Int.max), StatusIconGeometry.interior)
        XCTAssertNil(StatusIconGeometry.marker(at: Int.min))
        XCTAssertEqual(StatusIconGeometry.step(for: .nan), 0)
        XCTAssertEqual(StatusIconGeometry.step(for: .infinity), 0)
    }
}
