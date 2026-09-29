import Foundation
import VoxaAudio
import VoxaCore

/// An `AudioCapturing` whose audio and levels are pushed by the test.
public actor FakeAudioCapture: AudioCapturing {
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    public private(set) var isCapturing = false

    private var startError: (any Error)?
    private var chunkContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation?
    private var levelContinuation: AsyncStream<AudioLevel>.Continuation?
    private var emittedSamples = 0

    public init() {}

    /// Makes the next `start()` calls throw `error` (pass `nil` to clear).
    public func setStartError(_ error: (any Error)?) {
        startError = error
    }

    public func start() async throws -> AudioCaptureStreams {
        startCount += 1
        if let startError { throw startError }

        let (chunks, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let (levels, levelContinuation) = AsyncStream<AudioLevel>.makeStream()
        self.chunkContinuation = chunkContinuation
        self.levelContinuation = levelContinuation
        emittedSamples = 0
        isCapturing = true
        return AudioCaptureStreams(chunks: chunks, levels: levels)
    }

    public func stop() async {
        stopCount += 1
        chunkContinuation?.finish()
        levelContinuation?.finish()
        chunkContinuation = nil
        levelContinuation = nil
        isCapturing = false
    }

    /// Delivers `samples` samples of low-level noise (100 ms at the default).
    public func emitChunk(samples: Int = 1_600) {
        let chunk = AudioChunk(
            samples: [Float](repeating: 0.1, count: samples),
            startTime: Double(emittedSamples) / AudioChunk.canonicalSampleRate
        )
        emittedSamples += samples
        chunkContinuation?.yield(chunk)
    }

    public func emit(level: AudioLevel) {
        levelContinuation?.yield(level)
    }

    /// Ends the chunk stream with an error, as a lost input device would.
    public func fail(with error: any Error) {
        chunkContinuation?.finish(throwing: error)
    }
}
