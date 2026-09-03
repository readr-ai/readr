import XCTest
@testable import ReadrKit

/// Kokoro hands back Float32 samples; AVAudioPlayer wants a container. A
/// hand-rolled RIFF/WAVE writer is forty lines and needs no framework, so
/// it lives here where it can be checked byte by byte.
final class PCMWAVEncoderTests: XCTestCase {

    private func le32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self)
        }
    }

    private func le16(_ data: Data, _ offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt16.self)
        }
    }

    private func ascii(_ data: Data, _ offset: Int) -> String {
        String(decoding: data.subdata(in: offset..<(offset + 4)), as: UTF8.self)
    }

    func testHeaderDescribesSixteenBitMonoPCM() {
        let data = PCMWAVEncoder.data(samples: [0, 0.5, -0.5], sampleRate: 24_000)
        XCTAssertEqual(data.count, 44 + 3 * 2)
        XCTAssertEqual(ascii(data, 0), "RIFF")
        XCTAssertEqual(le32(data, 4), UInt32(data.count - 8))
        XCTAssertEqual(ascii(data, 8), "WAVE")
        XCTAssertEqual(ascii(data, 12), "fmt ")
        XCTAssertEqual(le32(data, 16), 16)          // PCM fmt chunk size
        XCTAssertEqual(le16(data, 20), 1)           // PCM
        XCTAssertEqual(le16(data, 22), 1)           // mono
        XCTAssertEqual(le32(data, 24), 24_000)      // sample rate
        XCTAssertEqual(le32(data, 28), 24_000 * 2)  // byte rate
        XCTAssertEqual(le16(data, 32), 2)           // block align
        XCTAssertEqual(le16(data, 34), 16)          // bits per sample
        XCTAssertEqual(ascii(data, 36), "data")
        XCTAssertEqual(le32(data, 40), 6)
    }

    func testSamplesAreScaledAndClampedToInt16() {
        let data = PCMWAVEncoder.data(samples: [0, 1, -1, 2, -2, 0.5], sampleRate: 8_000)
        let samples = (0..<6).map { Int16(bitPattern: le16(data, 44 + $0 * 2)) }
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], Int16.max)
        XCTAssertEqual(samples[2], Int16.min)
        XCTAssertEqual(samples[3], Int16.max, "over-range clamps rather than wrapping")
        XCTAssertEqual(samples[4], Int16.min)
        XCTAssertEqual(Double(samples[5]), 16_383, accuracy: 1)
    }

    func testNaNBecomesSilenceRatherThanNoise() {
        let data = PCMWAVEncoder.data(
            samples: [.nan, .infinity, -.infinity], sampleRate: 8_000
        )
        XCTAssertEqual(Int16(bitPattern: le16(data, 44)), 0)
        XCTAssertEqual(Int16(bitPattern: le16(data, 46)), Int16.max)
        XCTAssertEqual(Int16(bitPattern: le16(data, 48)), Int16.min)
    }

    func testAnEmptyBufferIsAValidEmptyFile() {
        let data = PCMWAVEncoder.data(samples: [], sampleRate: 24_000)
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(le32(data, 40), 0)
    }
}
