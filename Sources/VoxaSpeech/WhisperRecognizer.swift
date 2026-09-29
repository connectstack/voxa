import Foundation
import VoxaCore

/// Something that turns a stretch of speech into words: Whisper, behind a protocol so the recognizer around it is tested
/// without the model.
public protocol WhisperTranscribing: Sendable {
    /// The words in `samples` (mono, Float32, 16 kHz, the format the microphone capture produces).
    /// - Parameter language: An ISO language code such as `en`, or nil to let the model work out the language.
    func transcribe(_ samples: [Float], language: String?) async throws -> String
}

/// Hands the recognizer a transcriber that is ready to use.
public protocol WhisperTranscriberProviding: Sendable {
    /// Throws `SpeechError.whisperModelMissing` when the model hasn't been downloaded. Never downloads anything: a model is
    /// fetched only when the person asks for it in Settings.
    func transcriber(forModel id: String) async throws -> any WhisperTranscribing
}

/// Speech recognition with Whisper, on this Mac.
///
/// Whisper transcribes a finished piece of audio rather than a live stream, so live text is made by doing that again and again:
/// every second or so it transcribes everything heard so far and shows the result as a revisable guess, and when the audio
/// ends it transcribes the whole once more for the final text. A spoken command is a few seconds long, so this costs little.
public struct WhisperRecognizer: SpeechRecognizer {
    public struct Timing: Sendable, Equatable {
        /// How much new audio (in seconds) must arrive before the guess is refreshed.
        public var partialInterval: TimeInterval = 1.0
        /// Past this much audio the live guess stops, because transcribing it again and again would fall behind; the final text
        /// still covers everything.
        public var maxPartialAudio: TimeInterval = 28
        /// Less than this is a click or a breath, not speech.
        public var minimumAudio: TimeInterval = 0.3
        /// A peak below this, in a whole recording, is silence. It isn't sent to Whisper, which would make something up.
        public var silencePeak: Float = 0.004

        public init() {}
    }

    private let model: String
    private let transcribers: any WhisperTranscriberProviding
    private let timing: Timing

    public init(model: String, transcribers: any WhisperTranscriberProviding, timing: Timing = Timing()) {
        self.model = model
        self.transcribers = transcribers
        self.timing = timing
    }

    /// Whisper is not Apple's recognizer, so it needs no Speech Recognition permission. The microphone is the session's own.
    public func requiredPermissions(locale: Locale) async -> Set<PermissionKind> { [] }

    /// Loads the model into memory, so the first command doesn't wait for it.
    public func prepare(locale: Locale) async throws {
        _ = try await transcribers.transcriber(forModel: model)
    }

    /// The language to transcribe in: fixed for an English-only model, and the recognition language otherwise.
    static func language(model: String, locale: Locale) -> String? {
        if model.hasSuffix(".en") { return "en" }
        // "und" is how a locale says its language is unknown; Whisper is better off working the language out itself.
        guard let code = locale.language.languageCode?.identifier, code != "und" else { return nil }
        return code
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        let (model, transcribers, timing) = (model, transcribers, timing)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Loaded while the person is still speaking: the audio queues up meanwhile.
                    let transcriber = try await transcribers.transcriber(forModel: model)
                    let language = Self.language(model: model, locale: locale)
                    try await Self.listen(to: audio, with: transcriber, language: language, timing: timing, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func listen(
        to audio: AsyncThrowingStream<AudioChunk, any Error>,
        with transcriber: any WhisperTranscribing,
        language: String?,
        timing: Timing,
        into continuation: AsyncThrowingStream<Transcript, any Error>.Continuation
    ) async throws {
        var samples: [Float] = []
        var decodedUpTo = 0
        var lastGuess = ""
        let rate = AudioChunk.canonicalSampleRate

        for try await chunk in audio {
            samples.append(contentsOf: chunk.samples)
            let heard = Double(samples.count) / rate
            let fresh = Double(samples.count - decodedUpTo) / rate
            guard heard >= timing.minimumAudio, heard <= timing.maxPartialAudio, fresh >= timing.partialInterval else { continue }
            decodedUpTo = samples.count
            let guess = try await words(in: samples, with: transcriber, language: language, timing: timing)
            if !guess.isEmpty, guess != lastGuess {
                lastGuess = guess
                continuation.yield(Transcript(text: guess, isFinal: false))
            }
        }
        try Task.checkCancellation()
        let text = try await words(in: samples, with: transcriber, language: language, timing: timing)
        continuation.yield(Transcript(text: text, isFinal: true))
    }

    /// What was said in `samples`: nothing for a blip or for silence, otherwise Whisper's words with its sound annotations removed.
    private static func words(
        in samples: [Float],
        with transcriber: any WhisperTranscribing,
        language: String?,
        timing: Timing
    ) async throws -> String {
        guard Double(samples.count) / AudioChunk.canonicalSampleRate >= timing.minimumAudio,
            WhisperText.peak(samples) >= timing.silencePeak
        else { return "" }
        do {
            return WhisperText.clean(try await transcriber.transcribe(samples, language: language))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SpeechError {
            throw error
        } catch {
            throw SpeechError.whisperFailed(error.localizedDescription)
        }
    }
}
