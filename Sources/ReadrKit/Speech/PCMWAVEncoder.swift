import Foundation

/// Float samples → a RIFF/WAVE container (16-bit little-endian mono PCM),
/// which is what `AVAudioPlayer(data:)` plays. A neural synthesizer hands
/// back raw Float32 at its own sample rate; this is the whole of the glue.
public enum PCMWAVEncoder {

    /// Samples outside [-1, 1] clamp; NaN becomes silence.
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)

        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                                   // PCM chunk size
        append(UInt16(1))                                    // PCM
        append(UInt16(1))                                    // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))          // byte rate
        append(UInt16(bytesPerSample))                       // block align
        append(UInt16(16))                                   // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            guard !sample.isNaN else { continue }
            // Full-scale is 32768 so that -1 lands exactly on Int16.min; +1
            // would overflow by one and clamps to Int16.max instead.
            let scaled = min(max(sample, -1), 1) * 32768
            pcm[index] = scaled >= Float(Int16.max) ? Int16.max : Int16(scaled.rounded(.towardZero))
        }
        pcm.withUnsafeBufferPointer { buffer in
            // Int16 is written little-endian by construction on every Apple
            // and Linux target ReadrKit builds for; assert rather than swap.
            assert(1.littleEndian == 1)
            data.append(contentsOf: UnsafeRawBufferPointer(buffer))
        }
        return data
    }
}
