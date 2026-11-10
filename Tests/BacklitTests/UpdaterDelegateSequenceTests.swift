import XCTest
import Sparkle
@testable import Backlit

@MainActor final class UpdaterDelegateSequenceTests: XCTestCase {
    /// Construct the actual pinned SDK state through its NSSecureCoding API,
    /// rather than mocking the app's consent struct or using a private init.
    private final class StateDecoder: NSCoder {
        let stage: SPUUserUpdateStage
        init(_ stage: SPUUserUpdateStage) { self.stage = stage; super.init() }
        override var allowsKeyedCoding: Bool { true }
        override func decodeInteger(forKey key: String) -> Int { stage.rawValue }
        override func decodeBool(forKey key: String) -> Bool { false }
    }
    private func state(_ stage: SPUUserUpdateStage) throws -> SPUUserUpdateState {
        try XCTUnwrap(SPUUserUpdateState(coder: StateDecoder(stage)))
    }
    func testResumedInstallingPresentationBlocksQuitBeforeAnyChoiceOrInstallCallback() throws {
        let app = AppUpdater()
        XCTAssertTrue(app.allowsTermination())
        app.standardUserDriverWillHandleShowingUpdate(true, forUpdate: SUAppcastItem.empty(), state: try state(.installing))
        XCTAssertFalse(app.allowsTermination())
        XCTAssertFalse(app.consent.approved)
    }
    func testResumedInstallingDismissThenFinishDoesNotPermitOrdinaryQuit() throws {
        let app = AppUpdater()
        // Not started: no update check, UI, preferences or network activity.
        let sdk = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let item = SUAppcastItem.empty()
        app.standardUserDriverWillHandleShowingUpdate(true, forUpdate: item, state: try state(.installing))
        app.updater(sdk.updater, userDidMake: .dismiss, forUpdate: item, state: try state(.installing))
        app.updater(sdk.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertFalse(app.allowsTermination())
        app.updater(sdk.updater, userDidMake: .install, forUpdate: item, state: try state(.installing))
        XCTAssertTrue(app.allowsTermination())
    }
    func testSkipRequiresCycleCompletionAndFreshInstallApprovalSurvivesDismiss() throws {
        let app = AppUpdater()
        let sdk = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let item = SUAppcastItem.empty()
        app.updater(sdk.updater, willInstallUpdate: item)
        app.updater(sdk.updater, userDidMake: .skip, forUpdate: item, state: try state(.installing))
        XCTAssertFalse(app.allowsTermination())
        app.updater(sdk.updater, didFinishUpdateCycleFor: .updates, error: nil)
        XCTAssertTrue(app.allowsTermination())
        app.updater(sdk.updater, userDidMake: .install, forUpdate: item, state: try state(.downloaded))
        app.updater(sdk.updater, willInstallUpdate: item)
        app.updater(sdk.updater, userDidMake: .dismiss, forUpdate: item, state: try state(.installing))
        XCTAssertTrue(app.allowsTermination())
    }
}
