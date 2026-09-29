import Foundation
import VoxaCore

/// Whether the `SpeechAnalyzer` engine can serve a locale.
public enum AnalyzerReadiness: Sendable, Equatable {
    /// Supported and its model is installed.
    case ready
    /// Supported, but the model must be downloaded first.
    case needsDownload
    /// Not supported on this Mac, OS version, or for this language.
    case unavailable
}

/// Asks the system what the newer engine can do. A protocol so the selection logic is testable without hardware.
public protocol SpeechCapabilityProbing: Sendable {
    func analyzerReadiness(for locale: Locale) async -> AnalyzerReadiness
}

public struct SystemSpeechCapabilityProbe: SpeechCapabilityProbing {
    public init() {}

    public func analyzerReadiness(for locale: Locale) async -> AnalyzerReadiness {
        guard #available(macOS 26.0, *) else { return .unavailable }
        return await SpeechAnalyzerEngine.readiness(for: locale)
    }
}

/// Downloads the newer engine's language model in the background, at most once per language at a time.
public actor SpeechModelDownloader {
    private var inFlight: Set<String> = []

    public init() {}

    public func startIfNeeded(using engine: any SpeechRecognizer, locale: Locale) {
        let key = locale.identifier
        guard inFlight.insert(key).inserted else { return }
        Log.speech.info("downloading the on-device speech model in the background")
        Task {
            do {
                try await engine.prepare(locale: locale)
                Log.speech.info("speech model ready")
            } catch {
                Log.speech.error("speech model download failed: \(error.localizedDescription, privacy: .public)")
            }
            self.finished(key)
        }
    }

    private func finished(_ key: String) {
        inFlight.remove(key)
    }
}

/// "Automatic" engine selection: use the newer engine when its model is installed, otherwise the classic
/// recognizer, and fetch the newer model in the background so the *next* command benefits from it.
public struct AutomaticSpeechRecognizer: SpeechRecognizer {
    private let analyzer: (any SpeechRecognizer)?
    private let classic: any SpeechRecognizer
    private let probe: any SpeechCapabilityProbing
    private let downloader: SpeechModelDownloader
    private let allowsModelDownload: Bool

    /// - Parameters:
    ///   - analyzer: The newer engine, or `nil` on systems that lack it (then `classic` is always used).
    ///   - allowsModelDownload: Whether a missing model for the newer engine may be fetched in the background. When
    ///     `false` the classic engine is used until the model is installed some other way.
    public init(
        analyzer: (any SpeechRecognizer)?,
        classic: any SpeechRecognizer,
        probe: any SpeechCapabilityProbing,
        downloader: SpeechModelDownloader = SpeechModelDownloader(),
        allowsModelDownload: Bool = true
    ) {
        self.analyzer = analyzer
        self.classic = classic
        self.probe = probe
        self.downloader = downloader
        self.allowsModelDownload = allowsModelDownload
    }

    public func requiredPermissions(locale: Locale) async -> Set<PermissionKind> {
        if let analyzer, await probe.analyzerReadiness(for: locale) == .ready {
            return await analyzer.requiredPermissions(locale: locale)
        }
        return await classic.requiredPermissions(locale: locale)
    }

    public func prepare(locale: Locale) async throws {
        if let analyzer, await probe.analyzerReadiness(for: locale) != .unavailable {
            try await analyzer.prepare(locale: locale)
        } else {
            try await classic.prepare(locale: locale)
        }
    }

    public func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let engine = await chooseEngine(for: locale)
                    for try await transcript in engine.transcribe(audio, locale: locale) {
                        continuation.yield(transcript)
                    }
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

    private func chooseEngine(for locale: Locale) async -> any SpeechRecognizer {
        guard let analyzer else { return classic }
        switch await probe.analyzerReadiness(for: locale) {
        case .ready:
            return analyzer
        case .needsDownload:
            if allowsModelDownload {
                await downloader.startIfNeeded(using: analyzer, locale: locale)
            }
            return classic
        case .unavailable:
            return classic
        }
    }
}

/// The production recognizer factory.
public struct DefaultSpeechRecognizerProvider: SpeechRecognizerProviding {
    private let downloader = SpeechModelDownloader()

    public init() {}

    public func recognizer(for settings: AppSettings) -> any SpeechRecognizer {
        switch settings.speechEngine {
        case .appleClassic:
            return SFSpeechRecognizerEngine()
        case .appleAutomatic:
            let classic = SFSpeechRecognizerEngine()
            guard #available(macOS 26.0, *) else { return classic }
            return AutomaticSpeechRecognizer(
                analyzer: SpeechAnalyzerEngine(),
                classic: classic,
                probe: SystemSpeechCapabilityProbe(),
                downloader: downloader,
                allowsModelDownload: settings.downloadSpeechModel
            )
        }
    }
}
