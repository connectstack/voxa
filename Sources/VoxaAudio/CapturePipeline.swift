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
        var heard = LevelStatistics()
        var isFinished = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init() {
        state = OSAllocatedUnfairLock(initialState: State())
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
            state.heard.add(samples)
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
        let (isFirstCall, heard) = state.withLock { state -> (Bool, LevelStatistics) in
            let wasFinished = state.isFinished
            state.isFinished = true
            return (!wasFinished, state.heard)
        }
        guard isFirstCall else { return }
        if heard.seconds >= 0.3 {
            // Numbers only, never audio or words: how loud what the microphone gave was, for telling a microphone that is set too low
            // from a recognizer that mishears.
            Log.audio.info(
                "heard \(String(format: "%.1f", heard.seconds)) s: peak \(heard.peakDecibels) dBFS, average \(heard.rmsDecibels) dBFS"
            )
        }
        chunkContinuation.finish(throwing: error)
        levelContinuation.finish()
    }
}

/// How loud one capture was, for the log.
struct LevelStatistics: Sendable, Equatable {
    private(set) var samples = 0
    private(set) var peak: Float = 0
    private var sumOfSquares: Double = 0

    var seconds: Double { Double(samples) / AudioChunk.canonicalSampleRate }
    var peakDecibels: Int { Self.decibels(peak) }
    var rmsDecibels: Int { Self.decibels(samples > 0 ? Float((sumOfSquares / Double(samples)).squareRoot()) : 0) }

    mutating func add(_ block: [Float]) {
        for sample in block {
            peak = max(peak, abs(sample))
            sumOfSquares += Double(sample) * Double(sample)
        }
        samples += block.count
    }

    /// Decibels relative to full scale, rounded; silence is -120.
    static func decibels(_ linear: Float) -> Int {
        Int((20 * log10(max(linear, 1e-6))).rounded())
    }
}
