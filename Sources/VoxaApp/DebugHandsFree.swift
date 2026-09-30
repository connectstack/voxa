#if DEBUG
import Foundation
import VoxaAudio
import VoxaCore
import VoxaSpeech

// Debug builds only. They let a shell test hands-free listening in the real app without a person or a microphone: the "microphone"
// plays an audio file (made with `say`) once, in real time, then hears silence; and what the recognizer "hears" is scripted.
// Release builds never contain them, and nothing here does anything unless the app was launched with the variables below.
//
//   VOXA_DEBUG_HANDSFREE_AUDIO=/path/clip.wav       what hands-free's microphone hears, once, then silence
//   VOXA_DEBUG_HANDSFREE_TRANSCRIPTS="a|b|c"        what the Nth utterance is heard as (then empty)

/// A microphone that plays one file, in real time, and then keeps hearing silence until it is stopped. Stopping and starting it
/// again carries on from where the file had got to, so the file is only ever heard once.
actor DebugFileMicrophone: AudioCapturing {
    private let url: URL
    private var samples: [Float]?
    private var cursor = 0
    private var feeder: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    func start() async throws -> AudioCaptureStreams {
        feeder?.cancel()
        if samples == nil {
            var loaded: [Float] = []
            let streams = try await FileAudioCapture(url: url).start()
            for try await chunk in streams.chunks { loaded += chunk.samples }
            samples = loaded
        }
        let (chunks, chunkContinuation) = AsyncThrowingStream<AudioChunk, any Error>.makeStream()
        let (levels, levelContinuation) = AsyncStream<AudioLevel>.makeStream()
        feeder = Task { [weak self] in
            var emitted = 0
            while !Task.isCancelled {
                let piece = await self?.nextPiece() ?? [Float](repeating: 0, count: 1_600)
                chunkContinuation.yield(
                    AudioChunk(samples: piece, startTime: Double(emitted) / AudioChunk.canonicalSampleRate)
                )
                emitted += piece.count
                try? await Task.sleep(for: .milliseconds(100))
            }
            chunkContinuation.finish()
            levelContinuation.finish()
        }
        return AudioCaptureStreams(chunks: chunks, levels: levels)
    }

    func stop() async {
        feeder?.cancel()
        feeder = nil
    }

    private func nextPiece() -> [Float] {
        guard let samples, cursor < samples.count else { return [Float](repeating: 0, count: 1_600) }
        let end = min(cursor + 1_600, samples.count)
        defer { cursor = end }
        var piece = Array(samples[cursor..<end])
        if piece.count < 1_600 { piece += [Float](repeating: 0, count: 1_600 - piece.count) }
        return piece
    }
}

/// A recognizer that ignores the audio and says what it was told to: the Nth utterance is the Nth text.
final class DebugScriptedTranscripts: SpeechRecognizerProviding, SpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]

    init(_ texts: [String]) {
        self.texts = texts
    }

    func recognizer(for settings: AppSettings) -> any SpeechRecognizer { self }
    func requiredPermissions(locale: Locale) async -> Set<PermissionKind> { [] }
    func prepare(locale: Locale) async throws {}

    func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do { for try await _ in audio {} } catch {}
                let text = lock.withLock { texts.isEmpty ? "" : texts.removeFirst() }
                continuation.yield(Transcript(text: text, isFinal: true))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
