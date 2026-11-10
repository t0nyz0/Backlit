import XCTest
@testable import Backlit

final class AudioStateConcurrencyTests: XCTestCase {
    func testNeverStartedCaptureCanBeStoppedConcurrentlyWithoutIO() async {
        // Constructor/stop on a never-started instance do not create a tap,
        // request capture permission, or contact an audio/input device.
        let audio = SystemAudio()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    for _ in 0..<32 {
                        await audio.stop()
                        _ = audio.running
                        _ = audio.acceptsFailure(UInt64.max)
                    }
                }
            }
        }
        XCTAssertFalse(audio.running)
        XCTAssertEqual(audio.level, 0)
    }
}
