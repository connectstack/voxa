import AVFAudio
import Foundation
import VoxaCore

/// Synthetic audio for tests: known signals whose properties (length, frequency, level) can be asserted.
public enum TestSignal {
    public static func sine(
        frequency: Double = 440,
        sampleRate: Double = 16_000,
        seconds: Double = 1,
        amplitude: Float = 0.5
    ) -> [Float] {
        let count = Int(sampleRate * seconds)
        return (0..<count).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    /// A PCM buffer holding one array of samples per channel.
    public static func buffer(
        channels: [[Float]],
        sampleRate: Double,
        interleaved: Bool = false
    ) -> AVAudioPCMBuffer {
        let frames = channels.first?.count ?? 0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: interleaved
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData!
        if interleaved {
            for frame in 0..<frames {
                for channel in 0..<channels.count {
                    data[0][frame * channels.count + channel] = channels[channel][frame]
                }
            }
        } else {
            for (index, samples) in channels.enumerated() {
                for (frame, sample) in samples.enumerated() {
                    data[index][frame] = sample
                }
            }
        }
        return buffer
    }

    /// Number of sign changes; for a sine that is twice its frequency times its duration. Samples whose magnitude is
    /// below `threshold` are ignored so filter start-up noise around zero doesn't register as extra crossings.
    public static func zeroCrossings(_ samples: [Float], threshold: Float = 0.02) -> Int {
        var crossings = 0
        var previousSign: Float = 0
        for sample in samples where abs(sample) > threshold {
            let sign: Float = sample > 0 ? 1 : -1
            if previousSign != 0, previousSign != sign { crossings += 1 }
            previousSign = sign
        }
        return crossings
    }

    /// Writes mono samples to a 16-bit WAV file and returns its URL. The caller deletes it.
    public static func writeWAV(_ samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-test-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = buffer(channels: [samples], sampleRate: sampleRate)
        try file.write(from: buffer)
        return url
    }
}

extension AsyncThrowingStream where Element == AudioChunk, Failure == any Error {
    /// A finished stream that yields `chunks` — handy for feeding a recognizer without a capture object.
    public static func of(_ chunks: [AudioChunk]) -> AsyncThrowingStream<AudioChunk, any Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}
