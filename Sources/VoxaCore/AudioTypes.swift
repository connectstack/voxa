import AVFAudio
import Foundation

/// A slice of microphone audio in the canonical capture format: mono, Float32, 16 kHz.
///
/// 16 kHz is plenty for Apple's recognizers, so one format serves every
/// speech engine. Chunks are plain value types so they cross concurrency domains freely.
public struct AudioChunk: Sendable, Equatable {
    public static let canonicalSampleRate: Double = 16_000

    public let samples: [Float]
    public let sampleRate: Double
    /// Seconds from the start of the capture to the first sample of this chunk.
    public let startTime: TimeInterval

    public init(samples: [Float], sampleRate: Double = AudioChunk.canonicalSampleRate, startTime: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startTime = startTime
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    public var isEmpty: Bool { samples.isEmpty }
}

extension AudioChunk {
    /// Copies the samples into a new mono Float32 PCM buffer, the shape Apple's speech APIs consume.
    public func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard
            !samples.isEmpty,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: source.count)
            }
        }
        return buffer
    }
}

/// A perceptually scaled input level for the HUD meter. Both values are in `0...1`.
public struct AudioLevel: Sendable, Equatable {
    /// Smoothed RMS level (the "body" of the meter).
    public var rms: Float
    /// Instantaneous peak level.
    public var peak: Float

    public init(rms: Float, peak: Float) {
        self.rms = rms
        self.peak = peak
    }

    public static let silence = AudioLevel(rms: 0, peak: 0)
}
