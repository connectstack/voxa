import AVFAudio
import Foundation
import Speech
import VoxaCore

/// Speech recognition with `SpeechAnalyzer` / `SpeechTranscriber`, Apple's newer on-device engine (macOS 26+).
///
/// It is faster and more accurate than `SFSpeechRecognizer`, needs no Speech Recognition permission (the model runs
/// entirely on this Mac), and streams *volatile* results the HUD shows live. Its language model must be installed and
/// reserved for the app first; `prepare(locale:)` does both.
@available(macOS 26.0, *)
public struct SpeechAnalyzerEngine: SpeechRecognizer {
    public init() {}

    public func requiredPermissions(locale: Locale) async -> Set<PermissionKind> {
        []
    }

    public func prepare(locale: Locale) async throws {
        let resolved = try await Self.resolve(locale)
        try await Self.ensureAssets(for: Self.makeTranscriber(locale: resolved), locale: resolved)
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(audio: audio, locale: locale, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as SpeechError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: SpeechError.recognitionFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Readiness

    /// Whether this engine can transcribe `locale` right now, needs its model downloaded first, or can't at all.
    static func readiness(for locale: Locale) async -> AnalyzerReadiness {
        guard
            SpeechTranscriber.isAvailable,
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return .unavailable }

        switch await AssetInventory.status(forModules: [makeTranscriber(locale: resolved)]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsDownload
        case .unsupported: return .unavailable
        @unknown default: return .unavailable
        }
    }

    // MARK: Session

    private static func run(
        audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale,
        continuation: AsyncThrowingStream<Transcript, any Error>.Continuation
    ) async throws {
        let resolved = try await resolve(locale)
        let transcriber = makeTranscriber(locale: resolved)
        try await ensureAssets(for: transcriber, locale: resolved)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechError.recognizerUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)

        // Publishes the running transcript as results arrive and returns the final text once they end.
        let results = Task { () -> String in
            var assembler = TranscriptAssembler(locale: resolved)
            for try await result in transcriber.results {
                let display = assembler.apply(text: String(result.text.characters), isFinal: result.isFinal)
                continuation.yield(Transcript(text: display, isFinal: false))
            }
            return assembler.finalText
        }

        let converter = AnalyzerBufferConverter(target: format)
        do {
            for try await chunk in audio {
                if let buffer = converter.convert(chunk) {
                    inputContinuation.yield(AnalyzerInput(buffer: buffer))
                }
            }
        } catch {
            inputContinuation.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        inputContinuation.finish()

        if Task.isCancelled {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let finalText = try await results.value
        continuation.yield(Transcript(text: finalText, isFinal: true))
    }

    // MARK: Model management

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private static func resolve(_ locale: Locale) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw SpeechError.recognizerUnavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechError.unsupportedLocale(locale.identifier)
        }
        return supported
    }

    private static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported:
            throw SpeechError.unsupportedLocale(locale.identifier)
        case .installed:
            break
        case .supported, .downloading:
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw SpeechError.modelDownloadFailed(error.localizedDescription)
            }
        @unknown default:
            break
        }
        try await reserve(locale)
    }

    /// The system only keeps a locale's assets for apps that have reserved it. Voxa needs one language at a time,
    /// so any other reservation is released first to stay under the per-app limit.
    private static func reserve(_ locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return }
        for other in reserved {
            await AssetInventory.release(reservedLocale: other)
        }
        do {
            try await AssetInventory.reserve(locale: locale)
        } catch {
            throw SpeechError.modelDownloadFailed(error.localizedDescription)
        }
    }
}

// MARK: - Buffer conversion

/// Adapts canonical chunks to whatever format `SpeechAnalyzer` asks for (commonly 16-bit integer PCM).
@available(macOS 26.0, *)
private final class AnalyzerBufferConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        targetFormat = target
    }

    func convert(_ chunk: AudioChunk) -> AVAudioPCMBuffer? {
        guard let input = chunk.makePCMBuffer() else { return nil }
        if input.format == targetFormat { return input }

        if converter == nil {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        let feed = SingleBufferFeed(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Hands one buffer to `AVAudioConverter`, then reports "no data right now" so the converter keeps its state.
private final class SingleBufferFeed: @unchecked Sendable {
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
