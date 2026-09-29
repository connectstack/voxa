import AVFAudio
import Foundation
import VoxaCore

/// Plays an audio file through the same interface as the microphone.
///
/// Used by `voxa-dev transcribe` and by tests to drive the speech engines with known audio (for example a clip made
/// with `say`), so the recognition path can be exercised without a person, a microphone or a permission prompt.
public actor FileAudioCapture: AudioCapturing {
    /// Canonical samples per emitted chunk (100 ms).
    private static let chunkSize = 1_600

    private let url: URL
    private let realTime: Bool
    private var feeder: Task<Void, Never>?

    /// - Parameter realTime: Pace chunks at wall-clock speed (as a microphone would) instead of as fast as possible.
    public init(url: URL, realTime: Bool = false) {
        self.url = url
        self.realTime = realTime
    }

    public func start() async throws -> AudioCaptureStreams {
        feeder?.cancel()
        let samples = try Self.loadCanonicalSamples(from: url)
        let pipeline = CapturePipeline()
        let realTime = realTime

        feeder = Task.detached(priority: .userInitiated) {
            var index = 0
            while index < samples.count, !Task.isCancelled {
                let end = min(index + Self.chunkSize, samples.count)
                pipeline.emit(Array(samples[index..<end]))
                index = end
                if realTime {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            pipeline.finish()
        }
        return pipeline.streams
    }

    public func stop() async {
        feeder?.cancel()
        feeder = nil
    }

    private static func loadCanonicalSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioCaptureError.fileUnreadable(error.localizedDescription)
        }

        let converter = SpeechFormatConverter()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw AudioCaptureError.unsupportedFormat("buffer allocation failed")
        }

        var samples: [Float] = []
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                throw AudioCaptureError.fileUnreadable(error.localizedDescription)
            }
            guard buffer.frameLength > 0 else { break }
            samples += try converter.convert(buffer)
        }
        return samples
    }
}
