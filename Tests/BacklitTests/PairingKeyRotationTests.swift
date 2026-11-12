import XCTest
import Network
@testable import Backlit

/// A rotation that fails must never leave the old key working.
final class PairingKeyRotationTests: XCTestCase {
    func testSharingStopsBeforeTheStoredKeyChanges() {
        var order: [String] = []
        let outcome = PairingKeyRotation.run(wasSharing: true,
            stopSharing: { order.append("stop") }, regenerate: { order.append("regenerate") })
        XCTAssertEqual(order, ["stop", "regenerate"])
        XCTAssertEqual(outcome, .rotated(restartSharing: true))
    }

    func testSuccessfulRotationOnlyRestartsSharingThatWasOn() {
        XCTAssertEqual(PairingKeyRotation.run(wasSharing: false, stopSharing: {}, regenerate: {}), .rotated(restartSharing: false))
        XCTAssertEqual(PairingKeyRotation.run(wasSharing: true, stopSharing: {}, regenerate: {}), .rotated(restartSharing: true))
    }

    func testFailedRotationStopsSharingAndNeverAsksForARestart() {
        var stops = 0
        let outcome = PairingKeyRotation.run(wasSharing: true, stopSharing: { stops += 1 },
            regenerate: { throw RuntimeServices.failure("Keychain could not save the pairing key.") })
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(outcome, .failed("Keychain could not save the pairing key."))
    }

    @MainActor func testOldKeyIsRefusedByTheRealListenerAfterAFailedRotation() async throws {
        let server = HomeBridge()
        let ready = expectation(description: "ephemeral listener ready")
        server.onStatus = { if $0.contains("Available") { ready.fulfill() } }
        server.state = { ["id": "fixture", "controlling": true] }
        try server.start(lan: false, token: "old-fixture-key", port: 0)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.port)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/state")!)
        request.timeoutInterval = 3
        request.setValue("Bearer old-fixture-key", forHTTPHeaderField: "Authorization")
        let (_, before) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((before as? HTTPURLResponse)?.statusCode, 200, "The old key works before rotation")

        let outcome = PairingKeyRotation.run(wasSharing: true, stopSharing: { server.stop() },
            regenerate: { throw RuntimeServices.failure("fixture: new key could not be created") })
        guard case .failed = outcome else { return XCTFail("Expected a failed rotation") }

        // The listener is gone or refuses the session: the old key gets no answer.
        let after = try? await URLSession.shared.data(for: request)
        XCTAssertNotEqual((after?.1 as? HTTPURLResponse)?.statusCode, 200, "The old key must not work after a failed rotation")
        XCTAssertEqual(server.connectionCount, 0)
    }
}
