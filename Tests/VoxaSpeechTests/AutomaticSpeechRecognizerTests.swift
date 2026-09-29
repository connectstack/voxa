import Foundation
import Testing
import VoxaCore
@testable import VoxaSpeech
import VoxaTestSupport

/// Records how the automatic engine drives the engines behind it.
private final class RecordingRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _prepareCount = 0
    private var _transcribeCount = 0

    let name: String
    let permissions: Set<PermissionKind>
    /// When set, `prepare` waits on it, like a slow model download.
    let gate: AsyncGate?

    init(name: String, permissions: Set<PermissionKind> = [], gate: AsyncGate? = nil) {
        self.name = name
        self.permissions = permissions
        self.gate = gate
    }

    var prepareCount: Int { lock.withLock { _prepareCount } }
    var transcribeCount: Int { lock.withLock { _transcribeCount } }

    func requiredPermissions(locale: Locale) async -> Set<PermissionKind> { permissions }

    func prepare(locale: Locale) async throws {
        lock.withLock { _prepareCount += 1 }
        await gate?.wait()
    }

    func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        lock.withLock { _transcribeCount += 1 }
        let name = name
        return AsyncThrowingStream { continuation in
            continuation.yield(Transcript(text: "\(name) final", isFinal: true))
            continuation.finish()
        }
    }
}

private struct FixedProbe: SpeechCapabilityProbing {
    let readiness: AnalyzerReadiness
    func analyzerReadiness(for locale: Locale) async -> AnalyzerReadiness { readiness }
}

@Suite("AutomaticSpeechRecognizer")
struct AutomaticSpeechRecognizerTests {
    private let locale = Locale(identifier: "en_US")
    private let audio = AsyncThrowingStream<AudioChunk, any Error>.of([])

    private func transcribe(_ recognizer: AutomaticSpeechRecognizer) async throws -> [Transcript] {
        var transcripts: [Transcript] = []
        for try await transcript in recognizer.transcribe(audio, locale: locale) {
            transcripts.append(transcript)
        }
        return transcripts
    }

    @Test("uses the newer engine when its model is installed")
    func ready() async throws {
        let analyzer = RecordingRecognizer(name: "analyzer")
        let classic = RecordingRecognizer(name: "classic")
        let recognizer = AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .ready))

        let transcripts = try await transcribe(recognizer)
        #expect(transcripts.map(\.text) == ["analyzer final"])
        #expect(analyzer.transcribeCount == 1)
        #expect(classic.transcribeCount == 0)
    }

    @Test("falls back to the classic engine when the newer one is unavailable")
    func unavailable() async throws {
        let analyzer = RecordingRecognizer(name: "analyzer")
        let classic = RecordingRecognizer(name: "classic")
        let recognizer = AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .unavailable))

        #expect(try await transcribe(recognizer).map(\.text) == ["classic final"])
        #expect(analyzer.prepareCount == 0)
    }

    @Test("without a newer engine at all, classic is always used")
    func noAnalyzer() async throws {
        let classic = RecordingRecognizer(name: "classic")
        let recognizer = AutomaticSpeechRecognizer(analyzer: nil, classic: classic, probe: FixedProbe(readiness: .ready))
        #expect(try await transcribe(recognizer).map(\.text) == ["classic final"])
    }

    @Test("uses classic right now while the newer model downloads in the background, once")
    func needsDownload() async throws {
        let gate = AsyncGate()
        let analyzer = RecordingRecognizer(name: "analyzer", gate: gate)
        let classic = RecordingRecognizer(name: "classic")
        let recognizer = AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .needsDownload))

        // Two commands while the download is still running.
        #expect(try await transcribe(recognizer).map(\.text) == ["classic final"])
        #expect(try await transcribe(recognizer).map(\.text) == ["classic final"])

        #expect(await waitUntil { analyzer.prepareCount >= 1 })
        #expect(analyzer.prepareCount == 1, "the download must not be started twice")
        #expect(analyzer.transcribeCount == 0)
        await gate.open()
    }

    @Test("with downloads switched off, classic is used and the newer model is never fetched")
    func downloadDisabled() async throws {
        let analyzer = RecordingRecognizer(name: "analyzer")
        let classic = RecordingRecognizer(name: "classic")
        let recognizer = AutomaticSpeechRecognizer(
            analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .needsDownload), allowsModelDownload: false
        )

        #expect(try await transcribe(recognizer).map(\.text) == ["classic final"])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(analyzer.prepareCount == 0)
    }

    @Test("required permissions follow the engine that will actually run")
    func permissions() async {
        let analyzer = RecordingRecognizer(name: "analyzer", permissions: [])
        let classic = RecordingRecognizer(name: "classic", permissions: [.speechRecognition])

        let whenReady = AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .ready))
        #expect(await whenReady.requiredPermissions(locale: locale).isEmpty)

        let whenNot = AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .unavailable))
        #expect(await whenNot.requiredPermissions(locale: locale) == [.speechRecognition])
    }

    @Test("prepare targets the newer engine when it could serve the language, otherwise classic")
    func prepare() async throws {
        let analyzer = RecordingRecognizer(name: "analyzer")
        let classic = RecordingRecognizer(name: "classic")

        try await AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .needsDownload))
            .prepare(locale: locale)
        #expect(analyzer.prepareCount == 1)
        #expect(classic.prepareCount == 0)

        try await AutomaticSpeechRecognizer(analyzer: analyzer, classic: classic, probe: FixedProbe(readiness: .unavailable))
            .prepare(locale: locale)
        #expect(classic.prepareCount == 1)
    }

    @Test("errors from the chosen engine propagate")
    func errorsPropagate() async {
        let recognizer = AutomaticSpeechRecognizer(
            analyzer: nil,
            classic: ScriptedSpeechRecognizer(ending: .fails(SpeechError.recognizerUnavailable)),
            probe: FixedProbe(readiness: .unavailable)
        )
        do {
            _ = try await transcribe(recognizer)
            Issue.record("expected an error")
        } catch {
            #expect(error as? SpeechError == .recognizerUnavailable)
        }
    }
}

@Suite("Recognizer provider")
struct RecognizerProviderTests {
    @Test("the classic setting always yields the classic engine")
    func classic() {
        let recognizer = DefaultSpeechRecognizerProvider().recognizer(for: AppSettings(speechEngine: .appleClassic))
        #expect(recognizer is SFSpeechRecognizerEngine)
    }

    @Test("the automatic setting yields the selecting engine on macOS 26 and classic before it")
    func automatic() {
        let recognizer = DefaultSpeechRecognizerProvider().recognizer(for: AppSettings(speechEngine: .appleAutomatic))
        if #available(macOS 26.0, *) {
            #expect(recognizer is AutomaticSpeechRecognizer)
        } else {
            #expect(recognizer is SFSpeechRecognizerEngine)
        }
    }
}
