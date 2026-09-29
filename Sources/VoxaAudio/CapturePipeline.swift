import AVFAudio
import Foundation
import os
import VoxaCore

/// Owns the output streams of one capture and turns hardware buffers into canonical chunks plus levels.
///
/// `handle(_:)` is called from the audio engine's tap thread and `emit(_:)` from wherever a file feeder runs; all
/// mutable state sits behind an unfair lock and the stream continuations are themselves thread-safe, so the class is
/// safe to share even though the compiler can't prove it.
final class CapturePipeline: @unchecked Sendable {
    let streams: AudioCaptureStreams

    private let chunkContinuation: AsyncThrowingStream<AudioChunk, any Error>.Continuation
    private let levelContinuation: AsyncStream<AudioLevel>.Continuation
    private let converter = SpeechFormatConverter()

    private struct State {
        var samplesEmitted = 0
        var meter = LevelMeter()
        var isFinished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        let (chunks, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let (levels, levelContinuation) = AsyncStream<AudioLevel>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.chunkContinuation = chunkContinuation
        self.levelContinuation = levelContinuation
        self.streams = AudioCaptureStreams(chunks: chunks, levels: levels)
    }

    /// Converts a hardware buffer and publishes it. A conversion failure ends the capture with that error.
    func handle(_ buffer: AVAudioPCMBuffer) {
        do {
            emit(try converter.convert(buffer))
        } catch {
            finish(throwing: error)
        }
    }

    /// Publishes samples that are already in the canonical format.
    func emit(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let output = state.withLock { state -> (chunk: AudioChunk, level: AudioLevel)? in
            guard !state.isFinished else { return nil }
            let chunk = AudioChunk(
                samples: samples,
                startTime: Double(state.samplesEmitted) / AudioChunk.canonicalSampleRate
            )
            state.samplesEmitted += samples.count
            let level = state.meter.process(samples, sampleRate: AudioChunk.canonicalSampleRate)
            return (chunk, level)
        }
        guard let output else { return }
        chunkContinuation.yield(output.chunk)
        levelContinuation.yield(output.level)
    }

    /// Ends both streams. Idempotent; only the first call's error (if any) is delivered.
    func finish(throwing error: (any Error)? = nil) {
        let isFirstCall = state.withLock { state -> Bool in
            let wasFinished = state.isFinished
            state.isFinished = true
            return !wasFinished
        }
        guard isFirstCall else { return }
        chunkContinuation.finish(throwing: error)
        levelContinuation.finish()
    }
}
