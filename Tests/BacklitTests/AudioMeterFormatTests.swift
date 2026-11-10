import XCTest
@testable import Backlit

final class AudioMeterFormatTests: XCTestCase {
    func testSupportedFloatFormatsAndRatesProduceBoundedEnergy() {
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            let samples = (0..<2048).map { sin(2 * Double.pi * 80 * Double($0) / rate) * 0.1 }
            let meter = AudioEnergyMeter()
            samples.withUnsafeBytes { meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: rate, bits: 64) }
            XCTAssertTrue(meter.level.isFinite)
            XCTAssertGreaterThan(meter.level, 0.1)
            XCTAssertLessThanOrEqual(meter.level, 1)
            meter.reset()
            let floats = samples.map(Float.init)
            floats.withUnsafeBytes { meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: rate, bits: 32) }
            XCTAssertTrue((0...1).contains(meter.level))
        }
    }

    func testExtremeFinitePCMDoesNotPoisonSubsequentSilence() {
        let meter = AudioEnergyMeter()
        let damaged = [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude, 0, 1]
        damaged.withUnsafeBytes { meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: 48_000, bits: 64) }
        XCTAssertTrue(meter.level.isFinite)
        let silence = [Double](repeating: 0, count: 2048)
        for _ in 0..<32 {
            silence.withUnsafeBytes { meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: 48_000, bits: 64) }
        }
        XCTAssertTrue(meter.level.isFinite)
        XCTAssertLessThan(meter.level, 0.001)
    }

    func testAllInvalidPacketCannotResurrectPriorEnergyOnShortSilence() {
        for bits in [UInt32(32), UInt32(64)] {
            let meter = AudioEnergyMeter()
            func consume(_ values: [Double]) {
                if bits == 32 {
                    values.map(Float.init).withUnsafeBytes {
                        meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: 48_000, bits: bits)
                    }
                } else {
                    values.withUnsafeBytes {
                        meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: 48_000, bits: bits)
                    }
                }
            }
            consume(Array(repeating: 1, count: 64))
            XCTAssertGreaterThan(meter.level, 0.1)
            consume([.nan, .infinity, -.infinity])
            XCTAssertEqual(meter.level, 0)
            // A single valid silent frame must not revive the previous loud
            // low-pass state, even before the old stale-packet deadline.
            for _ in 0..<16 {
                consume([0])
                XCTAssertEqual(meter.level, 0, "Corrupt \(bits)-bit PCM must clear the old filter state")
            }
        }
    }

    func testUnalignedPCMAndIncompleteFramesAreSafe() {
        let samples = [Float](repeating: 0.1, count: 64)
        var bytes = Data([0])
        samples.withUnsafeBytes { bytes.append(contentsOf: $0) }
        let meter = AudioEnergyMeter()
        bytes.withUnsafeBytes {
            meter.consume($0.baseAddress!.advanced(by: 1), bytes: $0.count - 1, channels: 1, sampleRate: 48_000, bits: 32)
        }
        XCTAssertTrue((0...1).contains(meter.level))
        meter.reset()
        let partial = [Float(1)]
        partial.withUnsafeBytes { meter.consume($0.baseAddress!, bytes: $0.count, channels: 2, sampleRate: 48_000, bits: 32) }
        XCTAssertEqual(meter.level, 0, "An incomplete stereo frame is not usable audio")
    }

    func testInvalidRatesAndPacketsCannotCreateStuckEnergy() {
        let packet = [Float](repeating: 1, count: 64)
        for rate in [Double.nan, .infinity, 0, -1, .leastNonzeroMagnitude] {
            let meter = AudioEnergyMeter()
            packet.withUnsafeBytes { meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: rate, bits: 32) }
            XCTAssertEqual(meter.level, 0)
        }
        let meter = AudioEnergyMeter()
        packet.withUnsafeBytes {
            meter.consume($0.baseAddress!, bytes: -1, channels: 1, sampleRate: 48_000, bits: 32)
            meter.consume($0.baseAddress!, bytes: $0.count, channels: 0, sampleRate: 48_000, bits: 32)
            meter.consume($0.baseAddress!, bytes: $0.count, channels: 1, sampleRate: 48_000, bits: 16)
        }
        XCTAssertEqual(meter.level, 0)
    }
}
