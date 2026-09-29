import Foundation
import VoxaSpeech
@preconcurrency import WhisperKit

/// One loaded Whisper model, transcribing what it is given.
///
/// WhisperKit's objects aren't `Sendable`, so this class is the only thing that touches one, and it lets only one transcription
/// at a time through: the recognizer asks for a guess, then another, then the final text, and never overlaps them, but a second
/// command starting while the last one finishes must not either.
final class WhisperKitTranscriber: WhisperTranscribing, @unchecked Sendable {
    private let kit: WhisperKit
    private let turn = AsyncMutex()

    init(kit: WhisperKit) {
        self.kit = kit
    }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        await turn.lock()
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: Self.options(language: language))
            await turn.unlock()
            return results.map(\.text).joined(separator: " ")
        } catch {
            await turn.unlock()
            throw error
        }
    }

    /// Plain, deterministic decoding of one short utterance: no timestamps, no special tokens in the text, and, when the language
    /// isn't known, the model works it out.
    static func options(language: String?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false
        )
    }

    /// Frees the model's memory. It is loaded again the next time it is needed.
    func unload() async {
        await turn.lock()
        await kit.unloadModels()
        await turn.unlock()
    }
}

/// A lock for asynchronous code: whoever asks second waits, without blocking a thread, until the first is done.
actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if isLocked {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isLocked = true
        }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
