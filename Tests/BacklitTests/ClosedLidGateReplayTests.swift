import XCTest
@testable import Backlit

/// Deterministic model of documented fade/ready-gate behavior. This is a
/// software regression fixture, not evidence of the real Mac's capabilities.
final class ClosedLidGateReplayTests: XCTestCase {
    final class Model {
        var now = 0.0
        var duration = 0.3
        var state = 1
        var startFactor = 0.0
        var startTime = 0.0
        var fadeDuration = 0.3
        var factor: Double {
            let elapsed = max(0,now-startTime)
            let phase = min(1,elapsed/max(0.001,fadeDuration))
            let progress = phase >= 1 ? 1 : 1-(1+6.51*phase)*exp(-6.51*phase)
            return startFactor + ((state == 2 ? 1.0 : 0.0)-startFactor)*progress
        }
        func make() -> ClosedLidEffect {
            .init(interface:.init(sample:{ .init(factor:self.factor,appliedNits:856,multiplier:1) }, duration:{ self.duration=$0;return true }, logicalState:{ next in
                guard next != self.state else { return true }
                let current=self.factor
                self.startFactor=current;self.state=next;self.fadeDuration=self.duration == 0 ? 0.3 : self.duration
                self.startTime=self.now + (next == 2 && current == 0 ? 0.65 : 0.017)
                return true
            }, keepKeyboardDark:{ true }, now:{ self.now }))
        }
    }
    func testChangingBreatheRequestsAllowDelayedFirstRise() throws {
        let model=Model(),controller=model.make()
        var maximum=0.0
        for tick in 0..<80 {
            model.now=Double(tick)*0.05
            let target=0.04 + 0.9*(1-cos(model.now*2))/2
            try controller.apply(target)
            maximum=max(maximum,model.factor)
        }
        XCTAssertGreaterThan(maximum,0.5,"Changing effect requests must not continually rearm the zero-rise gate")
    }
    func testStaticInteriorSettlesWithoutContinuousEndpointHunting() throws {
        let model=Model(),controller=model.make()
        var tail:[Double]=[]
        for tick in 0..<100 {
            model.now=Double(tick)*0.05;try controller.apply(0.3)
            if tick>70 {tail.append(model.factor)}
        }
        XCTAssertTrue(tail.allSatisfy { abs($0-0.3)<0.025 },"Steady interior output should hold after settling")
    }
    func testDelayedLowSteadyStartupDoesNotFlashFullScale() throws {
        let model=Model(),controller=model.make();var peak=0.0
        for tick in 0..<50 {
            model.now=Double(tick)*0.05;try controller.apply(0.3);peak=max(peak,model.factor)
        }
        XCTAssertLessThan(peak,0.4)
    }

}
