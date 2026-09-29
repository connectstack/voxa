import Foundation
import Speech
import VoxaCore

/// Speech recognition with `SFSpeechRecognizer`, available on every supported macOS version.
///
/// Privacy: recognition is forced on-device. If the language has no on-device model, the engine fails with a
/// message explaining how to install one instead of silently sending the user's voice to Apple's servers. Server
/// recognition can only be enabled explicitly with `allowServerRecognition`.
public struct SFSpeechRecognizerEngine: SpeechRecognizer {
    private let allowServerRecognition: Bool

    public init(allowServerRecognition: Bool = false) {
        self.allowServerRecognition = allowServerRecognition
    }

    public func requiredPermissions(locale: Locale) async -> Set<PermissionKind> {
        [.speechRecognition]
    }

    public func prepare(locale: Locale) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw SpeechError.unsupportedLocale(locale.identifier)
        }
        guard recognizer.supportsOnDeviceRecognition || allowServerRecognition else {
            throw SpeechError.onDeviceUnavailable(languageName: locale.voxaDisplayName)
        }
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        let allowServer = allowServerRecognition
        return AsyncThrowingStream { continuation in
            let status = SFSpeechRecognizer.authorizationStatus()
            guard status == .authorized else {
                continuation.finish(throwing: SpeechError.notAuthorized(PermissionStatus(status)))
                return
            }
            guard let recognizer = SFSpeechRecognizer(locale: locale) else {
                continuation.finish(throwing: SpeechError.unsupportedLocale(locale.identifier))
                return
            }
            guard recognizer.isAvailable else {
                continuation.finish(throwing: SpeechError.recognizerUnavailable)
                return
            }
            guard recognizer.supportsOnDeviceRecognition || allowServer else {
                continuation.finish(throwing: SpeechError.onDeviceUnavailable(languageName: locale.voxaDisplayName))
                return
            }

            let session = SFSpeechSession(
                recognizer: recognizer,
                onDevice: recognizer.supportsOnDeviceRecognition,
                continuation: continuation
            )
            session.start()

            let feeder = Task {
                do {
                    for try await chunk in audio {
                        session.append(chunk)
                    }
                    session.endAudio()
                } catch {
                    session.fail(with: error)
                }
            }
            continuation.onTermination = { _ in
                feeder.cancel()
                session.cancel()
            }
        }
    }
}

// MARK: - Error classification

/// How a Speech-framework error should be treated. Internal so tests can pin the mapping.
enum SFSpeechErrorClassification: Equatable {
    /// The recognizer heard nothing. A normal outcome that ends in an empty final transcript.
    case noSpeech
    /// The task was cancelled by us (or the user).
    case cancelled
    case failure(SpeechError)

    static func classify(_ error: any Error) -> SFSpeechErrorClassification {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            switch nsError.code {
            case 1110: return .noSpeech
            case 216, 301: return .cancelled
            default: break
            }
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return .cancelled
        }
        return .failure(.recognitionFailed(nsError.localizedDescription))
    }
}

// MARK: - Session

/// Owns one `SFSpeechRecognitionTask`. The Speech framework's types aren't `Sendable`, so they are confined to this
/// class and every access goes through `lock`; results arrive on a private serial queue (never the main queue).
private final class SFSpeechSession: @unchecked Sendable {
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let recognizer: SFSpeechRecognizer
    private let continuation: AsyncThrowingStream<Transcript, any Error>.Continuation
    private let queue = OperationQueue()

    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var isFinished = false

    init(
        recognizer: SFSpeechRecognizer,
        onDevice: Bool,
        continuation: AsyncThrowingStream<Transcript, any Error>.Continuation
    ) {
        self.recognizer = recognizer
        self.continuation = continuation
        queue.name = "com.rohitsainier.voxa.speech"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        recognizer.queue = queue

        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.taskHint = .dictation
        request.addsPunctuation = true
    }

    func start() {
        let newTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
        lock.withLock { task = newTask }
    }

    func append(_ chunk: AudioChunk) {
        guard let buffer = chunk.makePCMBuffer() else { return }
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }

    /// The audio source failed: stop recognizing and surface the error to the consumer.
    func fail(with error: any Error) {
        request.endAudio()
        lock.withLock { task }?.cancel()
        finish(with: error)
    }

    /// The consumer went away: tear everything down without emitting anything more.
    func cancel() {
        lock.withLock { isFinished = true }
        request.endAudio()
        lock.withLock { task }?.cancel()
    }

    // MARK: Results

    private func handle(result: SFSpeechRecognitionResult?, error: (any Error)?) {
        if let result {
            let text = result.bestTranscription.formattedString
            let alreadyFinished = lock.withLock { () -> Bool in
                lastText = text
                return isFinished
            }
            guard !alreadyFinished else { return }

            if result.isFinal {
                continuation.yield(Transcript(text: text, isFinal: true, confidence: Self.confidence(of: result)))
                finish(with: nil)
                return
            }
            continuation.yield(Transcript(text: text, isFinal: false))
        }

        guard let error else { return }
        switch SFSpeechErrorClassification.classify(error) {
        case .cancelled:
            finish(with: nil)
        case .noSpeech:
            continuation.yield(Transcript(text: "", isFinal: true))
            finish(with: nil)
        case .failure(let speechError):
            // A late error after we already heard words is better treated as "that's what was said".
            let salvaged = lock.withLock { lastText }
            if salvaged.isEmpty {
                finish(with: speechError)
            } else {
                Log.speech.warning("recognizer error after partial result; using the last hypothesis")
                continuation.yield(Transcript(text: salvaged, isFinal: true))
                finish(with: nil)
            }
        }
    }

    private func finish(with error: (any Error)?) {
        let isFirstCall = lock.withLock { () -> Bool in
            let wasFinished = isFinished
            isFinished = true
            return !wasFinished
        }
        guard isFirstCall else { return }
        continuation.finish(throwing: error)
    }

    private static func confidence(of result: SFSpeechRecognitionResult) -> Float? {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return nil }
        return segments.reduce(0) { $0 + $1.confidence } / Float(segments.count)
    }
}
