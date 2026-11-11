import XCTest
@testable import Backlit

@MainActor final class HardwareRecoveryReentrancyTests: XCTestCase {
    func model(hardwareRestore: (() throws -> Void)? = nil) -> AppModel {
        let name="local.backlit.test.recovery."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        addTeardownBlock {defaults.removePersistentDomain(forName:name)}
        return AppModel(demo:true,defaults:defaults,hardwareRestore:hardwareRestore)
    }
    func testPumpedCallbacksCannotReenterRecoveryOrChangeOwnership() {
        let m=model();m.controlWanted=true
        var nested=false
        XCTAssertTrue(m.withHardwareRecovery {
            XCTAssertTrue(m.hardwareRecoveryInProgress)
            XCTAssertFalse(m.withHardwareRecovery {nested=true})
            XCTAssertFalse(m.withHardwareApply {nested=true})
            m.tick();m.releaseHardware();m.restore();m.repairAndResume();m.setControl(false)
            XCTAssertFalse(m.prepareQuit())
            XCTAssertTrue(m.controlWanted)
        })
        XCTAssertFalse(nested);XCTAssertFalse(m.hardwareRecoveryInProgress)
        XCTAssertTrue(m.withHardwareRecovery {})
    }
    func testThrowClearsGateForLaterRecovery() {
        let m=model()
        XCTAssertThrowsError(try m.withHardwareRecovery {throw NSError(domain:"fixture",code:1)})
        XCTAssertFalse(m.hardwareRecoveryInProgress)
        XCTAssertTrue(m.withHardwareRecovery {})
    }

    func testApplyPumpedCallbacksCannotNestAnyHardwareOperationOrStopRoutineAudio() {
        var restores = 0, nested = 0
        let m = model(hardwareRestore: { restores += 1 })
        m.mode = .steady; m.brightness = 0.3; m.tick()
        let output = m.output
        m.brightness = 0.9
        m.controlWanted = true; m.controlling = true; m.keepClosed = true
        // Only a published fixture flag, never a real capture session.
        m.audioRunning = true
        XCTAssertTrue(m.withHardwareApply {
            m.updateMusicHardwareReadiness {
                XCTAssertTrue(m.hardwareApplyInProgress)
                XCTAssertTrue(m.hardwareOperationInProgress)
                XCTAssertFalse(m.hardwareRecoveryInProgress)
                XCTAssertFalse(m.lifecycleAllowsFrames)
                XCTAssertFalse(m.withHardwareApply { nested += 1 })
                XCTAssertFalse(m.withHardwareRecovery { nested += 1 })
                XCTAssertFalse(m.completePowerRecovery { nested += 1 })
                m.tick(); m.setControl(false); m.restore(); m.repairAndResume()
                m.releaseHardware(); m.setLid(false); m.stopLid(); m.setAmbient(true)
                XCTAssertFalse(m.prepareQuit())
                XCTAssertEqual(m.output, output)
                XCTAssertTrue(m.controlWanted); XCTAssertTrue(m.controlling)
                XCTAssertTrue(m.keepClosed, "Nested cleanup cannot revoke the owned lid policy")
                XCTAssertFalse(m.lidStopPending)
                XCTAssertTrue(m.audioRunning, "The routine apply gate must not stop capture")
                return .applied
            }
        })
        XCTAssertEqual(nested, 0); XCTAssertEqual(restores, 0)
        XCTAssertFalse(m.hardwareOperationInProgress); XCTAssertTrue(m.lifecycleAllowsFrames)
        XCTAssertTrue(m.audioRunning)
        m.controlling = false; m.keepClosed = false; m.audioRunning = false
        XCTAssertTrue(m.prepareQuit())
    }

    func testThrowFromApplyClearsGateWithoutEnteringRecovery() {
        let m = model()
        XCTAssertThrowsError(try m.withHardwareApply {
            throw NSError(domain: "fixture.apply", code: 1)
        })
        XCTAssertFalse(m.hardwareApplyInProgress)
        XCTAssertFalse(m.hardwareRecoveryInProgress)
        XCTAssertTrue(m.withHardwareApply {})
        XCTAssertTrue(m.withHardwareRecovery {})
        XCTAssertTrue(m.prepareQuit())
    }
}
