import Accelerate
import AVFAudio
import Foundation
import VoxaCore

/// Converts whatever the audio hardware (or a file) delivers into the canonical speech format: mono Float32 at 16 kHz.
///
/// Multi-channel input is averaged to mono by hand (deterministic for any channel layout), then resampled with
/// `AVAudioConverter` at high quality. The converter is cached and reused across buffers so its filter state carries
/// over between calls, and it is rebuilt automatically when the input rate changes (e.g. AirPods switching to their
/// hands-free microphone profile mid-session).
///
/// Instances are used from one audio thread at a time; the lock only guards against accidental sharing.
public final class SpeechFormatConverter: @unchecked Sendable {
    public let targetSampleRate: Double

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterSourceRate: Double = 0

    public init(targetSampleRate: Double = AudioChunk.canonicalSampleRate) {
        self.targetSampleRate = targetSampleRate
    }

    /// Converts one buffer. Returns an empty array for an empty buffer.
    public func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let mono = try Self.monoSamples(from: buffer)
        let sourceRate = buffer.format.sampleRate
        guard sourceRate > 0 else { throw AudioCaptureError.unsupportedFormat("0 Hz") }
        if abs(sourceRate - targetSampleRate) < 0.5 { return mono }
        return try resample(mono, from: sourceRate)
    }

    /// Converts already-mono samples at `sourceRate` (used by file input and tests).
    public func convert(monoSamples: [Float], sourceRate: Double) throws -> [Float] {
        guard !monoSamples.isEmpty else { return [] }
        guard sourceRate > 0 else { throw AudioCaptureError.unsupportedFormat("0 Hz") }
        if abs(sourceRate - targetSampleRate) < 0.5 { return monoSamples }
        return try resample(monoSamples, from: sourceRate)
    }

    // MARK: Mono mixdown

    static func monoSamples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard let channels = buffer.floatChannelData else {
            throw AudioCaptureError.unsupportedFormat("non-Float32 PCM")
        }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { throw AudioCaptureError.unsupportedFormat("0 channels") }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        }

        var mono = [Float](repeating: 0, count: frames)
        if buffer.format.isInterleaved {
            let interleaved = channels[0]
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleaved[frame * channelCount + channel]
                }
                mono[frame] = sum / Float(channelCount)
            }
        } else {
            mono.withUnsafeMutableBufferPointer { output in
                let base = output.baseAddress!
                for channel in 0..<channelCount {
                    vDSP_vadd(base, 1, channels[channel], 1, base, 1, vDSP_Length(frames))
                }
                var scale = 1 / Float(channelCount)
                vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(frames))
            }
        }
        return mono
    }

    // MARK: Resampling

    private func resample(_ mono: [Float], from sourceRate: Double) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        if converter == nil || converterSourceRate != sourceRate {
            guard
                let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false
                ),
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false
                ),
                let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
            else {
                throw AudioCaptureError.unsupportedFormat("\(Int(sourceRate)) Hz")
            }
            newConverter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            newConverter.primeMethod = .none
            converter = newConverter
            converterSourceRate = sourceRate
        }
        guard let converter else { throw AudioCaptureError.unsupportedFormat("converter unavailable") }

        guard
            let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(mono.count)),
            let inputChannel = input.floatChannelData?[0]
        else {
            throw AudioCaptureError.unsupportedFormat("input buffer allocation failed")
        }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { inputChannel.update(from: $0.baseAddress!, count: $0.count) }

        let capacity = AVAudioFrameCount((Double(mono.count) * targetSampleRate / sourceRate).rounded(.up)) + 64
        guard
            let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity),
            let outputChannel = output.floatChannelData?[0]
        else {
            throw AudioCaptureError.unsupportedFormat("output buffer allocation failed")
        }

        let feed = OneShotFeed(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        if status == .error {
            throw AudioCaptureError.unsupportedFormat(conversionError?.localizedDescription ?? "conversion failed")
        }
        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(output.frameLength)))
    }
}

/// Supplies a single buffer to `AVAudioConverter`, then reports "no data right now" so the converter keeps its state.
private final class OneShotFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            status.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        status.pointee = .haveData
        return buffer
    }
}
