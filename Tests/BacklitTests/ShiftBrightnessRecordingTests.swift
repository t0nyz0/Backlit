import XCTest
@testable import Backlit

final class ShiftBrightnessRecordingTests: XCTestCase {
    private func event(_ action: LogoShortcutAction = .increase, down: Bool = true,
                       repeated: Bool = false, shift: Bool = true) -> ShiftBrightnessEvent {
        .init(action: action, down: down, repeated: repeated, exactShift: shift)
    }
    func testRecordingBoundaryCancelsQueuedActionsWithoutReturningAnOwnedHoldToMacOS() {
        var state = ShiftBrightnessGestureState()
        XCTAssertEqual(state.handle(event(), at: 1), .init(consume: true, action: .increase))
        let queuedBeforeRecorder = state.actionGeneration
        state.cancelPendingActions()
        XCTAssertFalse(state.acceptsAction(generation: queuedBeforeRecorder))
        XCTAssertEqual(state.handle(event(repeated: true, shift: false), at: 2), .init(consume: true, action: nil))
        state.cancelPendingActions() // Dismissing the recorder cancels its pending work too.
        XCTAssertEqual(state.handle(event(repeated: true), at: 3), .init(consume: true, action: .increase))
        XCTAssertEqual(state.handle(event(down: false, shift: false), at: 4), .init(consume: true, action: nil))
        XCTAssertEqual(state.handle(event(down: false), at: 5), .pass)
    }
    func testNativeHoldStaysNativeAndOtherDirectionRemainsIndependentAcrossRecorder() {
        var state = ShiftBrightnessGestureState()
        XCTAssertEqual(state.handle(event(shift: false), at: 1), .pass)
        XCTAssertEqual(state.handle(event(.decrease), at: 2), .init(consume: true, action: .decrease))
        state.cancelPendingActions()
        XCTAssertEqual(state.handle(event(repeated: true), at: 3), .pass)
        XCTAssertEqual(state.handle(event(.decrease, repeated: true, shift: false), at: 3), .init(consume: true, action: nil))
        XCTAssertEqual(state.handle(event(down: false), at: 4), .pass)
        XCTAssertEqual(state.handle(event(.decrease, down: false), at: 4), .init(consume: true, action: nil))
    }
    func testFullListenerResetStillReturnsControlAndInvalidatesQueuedActions() {
        var state = ShiftBrightnessGestureState()
        _ = state.handle(event(), at: 1)
        let queued = state.actionGeneration
        state.reset()
        XCTAssertFalse(state.acceptsAction(generation: queued))
        XCTAssertEqual(state.handle(event(repeated: true), at: 2), .pass)
        XCTAssertEqual(state.handle(event(down: false), at: 3), .pass)
        XCTAssertEqual(state.handle(event(shift: false), at: 4), .pass)
    }
    func testOnlyCurrentActionTokenCanDeliverAfterMultipleRecorderTransitions() {
        var state = ShiftBrightnessGestureState()
        _ = state.handle(event(), at: 1)
        var tokens = [state.actionGeneration]
        for _ in 0..<3 { state.cancelPendingActions(); tokens.append(state.actionGeneration) }
        XCTAssertTrue(state.acceptsAction(generation: tokens.removeLast()))
        XCTAssertTrue(tokens.allSatisfy { !state.acceptsAction(generation: $0) })
    }
}
