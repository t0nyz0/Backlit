import XCTest
@testable import Backlit

@MainActor final class HardwareRecoveryReentrancyTests: XCTestCase {
    func model() -> AppModel {
        let name="local.backlit.test.recovery."+UUID().uuidString
        let defaults=UserDefaults(suiteName:name)!
        addTeardownBlock {defaults.removePersistentDomain(forName:name)}
        return AppModel(demo:true,defaults:defaults)
    }
    func testPumpedCallbacksCannotReenterRecoveryOrChangeOwnership() {
        let m=model();m.controlWanted=true
        var nested=false
        XCTAssertTrue(m.withHardwareRecovery {
            XCTAssertTrue(m.hardwareRecoveryInProgress)
            XCTAssertFalse(m.withHardwareRecovery {nested=true})
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
}
