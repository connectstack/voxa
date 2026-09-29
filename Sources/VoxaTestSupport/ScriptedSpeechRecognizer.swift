import Foundation
import VoxaCore
import VoxaSpeech

/// A recognizer that plays a script instead of listening: one partial transcript per audio chunk received, then a
/// configurable ending once the audio stream finishes.
public struct ScriptedSpeechRecognizer: SpeechRecognizer {
    public enum Ending: Sendable {
        /// Emit this final transcript and finish.
        case completes(final: String)
        /// Finish by throwing.
        case fails(any Error)
        /// Never deliver a final transcript (until cancelled), like a wedged recognizer.
        case neverFinishes
    }

    public var partials: [String]
    public var ending: Ending
    public var permissions: Set<PermissionKind>

    public init(
        partials: [String] = [],
        ending: Ending = .completes(final: ""),
        permissions: Set<PermissionKind> = []
    ) {
        self.partials = partials
        self.ending = ending
        self.permissions = permissions
    }

    public func requiredPermissions(locale: Locale) async -> Set<PermissionKind> {
        permissions
    }

    public func prepare(locale: Locale) async throws {}

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        let partials = partials
        let ending = ending
        return AsyncThrowingStream { continuation in
            let task = Task {
                var index = 0
                do {
                    for try await _ in audio where index < partials.count {
                        continuation.yield(Transcript(text: partials[index], isFinal: false))
                        index += 1
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                switch ending {
                case .completes(let final):
                    continuation.yield(Transcript(text: final, isFinal: true))
                    continuation.finish()
                case .fails(let error):
                    continuation.finish(throwing: error)
                case .neverFinishes:
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct FixedRecognizerProvider: SpeechRecognizerProviding {
    private let recognizer: any SpeechRecognizer

    public init(_ recognizer: any SpeechRecognizer) {
        self.recognizer = recognizer
    }

    public func recognizer(for settings: AppSettings) -> any SpeechRecognizer {
        recognizer
    }
}

/// Hands out a different recognizer for each command, in order (the last one repeats), for tests that speak more than once.
public final class SequencedRecognizerProvider: SpeechRecognizerProviding, @unchecked Sendable {
    private let recognizers: [any SpeechRecognizer]
    private let lock = NSLock()
    private var next = 0

    public init(_ recognizers: [any SpeechRecognizer]) {
        precondition(!recognizers.isEmpty)
        self.recognizers = recognizers
    }

    public func recognizer(for settings: AppSettings) -> any SpeechRecognizer {
        lock.lock()
        defer { lock.unlock() }
        let index = min(next, recognizers.count - 1)
        next += 1
        return recognizers[index]
    }
}
