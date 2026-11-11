import XCTest
@testable import Backlit

final class PreviewMusicTests: XCTestCase {
    @MainActor func testPreviewRunsMusicControlsThroughTheLiveResponseWithoutCapture() {
        let suite = "local.backlit.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let model = AppModel(demo: true, defaults: defaults)
        defer {
            XCTAssertTrue(model.prepareQuit())
            defaults.removePersistentDomain(forName: suite)
        }
        model.mode = .music
        model.brightness = 1
        model.musicPreset = .balanced
        model.musicAutomatic = true
        model.tick()
        let automatic = model.output
        XCTAssertGreaterThan(automatic, 0.58)
        XCTAssertLessThan(automatic, 0.62, "Automatic level leaves intensity headroom")

        model.musicAutomatic = false
        model.tick()
        let manual = model.output
        XCTAssertGreaterThan(manual, 0)
        XCTAssertLessThan(manual, automatic)

        model.musicPreset = .punchy
        model.tick()
        XCTAssertLessThan(model.output, manual)

        model.musicAutomatic = true
        model.musicPreset = .smooth
        model.tick()
        XCTAssertGreaterThan(model.output, 0)
        XCTAssertLessThan(model.output, 0.43)
        XCTAssertFalse(model.audioRunning)
        XCTAssertFalse(model.audioStarting)
        XCTAssertFalse(model.controlling)
        XCTAssertFalse(model.controlWanted)
        model.startAudio()
        XCTAssertFalse(model.audioRunning)
        XCTAssertTrue(model.notice?.contains("sample waveform") == true)
    }
}
