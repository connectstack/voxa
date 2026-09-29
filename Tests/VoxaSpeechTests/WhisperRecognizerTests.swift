import Foundation
import Testing
import VoxaCore
@testable import VoxaSpeech
import VoxaTestSupport

/// A Whisper that answers from a script, and remembers what it was asked.
private final class FakeWhisper: WhisperTranscribing, @unchecked Sendable {
    struct Call: Equatable {
        var seconds: Double
        var language: String?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let reply: @Sendable (Double) throws -> String

    init(_ reply: @escaping @Sendable (Double) throws -> String = { "heard \(Int($0.rounded())) seconds" }) {
        self.reply = reply
    }

    var calls: [Call] { lock.withLock { _calls } }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let seconds = Double(samples.count) / AudioChunk.canonicalSampleRate
        lock.withLock { _calls.append(Call(seconds: seconds, language: language)) }
        return try reply(seconds)
    }
}

private struct FakeTranscribers: WhisperTranscriberProviding {
    var whisper: FakeWhisper?
    var requested: RequestLog = RequestLog()

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _models: [String] = []
        var models: [String] { lock.withLock { _models } }
        func add(_ id: String) { lock.withLock { _models.append(id) } }
    }

    func transcriber(forModel id: String) async throws -> any WhisperTranscribing {
        requested.add(id)
        guard let whisper else { throw SpeechError.whisperModelMissing(name: id) }
        return whisper
    }
}

/// `seconds` of a tone, in tenth-of-a-second chunks, like the microphone would deliver it.
private func speech(seconds: Double, amplitude: Float = 0.2) -> AsyncThrowingStream<AudioChunk, any Error> {
    AsyncThrowingStream { continuation in
        let chunks = Int((seconds * 10).rounded())
        for index in 0..<chunks {
            continuation.yield(AudioChunk(samples: [Float](repeating: amplitude, count: 1_600), startTime: Double(index) / 10))
        }
        continuation.finish()
    }
}

private func collect(_ stream: AsyncThrowingStream<Transcript, any Error>) async throws -> [Transcript] {
    var all: [Transcript] = []
    for try await transcript in stream { all.append(transcript) }
    return all
}

@Suite("WhisperRecognizer")
struct WhisperRecognizerTests {
    private func recognizer(
        _ whisper: FakeWhisper?,
        model: String = "base.en",
        timing: WhisperRecognizer.Timing = .init()
    ) -> WhisperRecognizer {
        WhisperRecognizer(model: model, transcribers: FakeTranscribers(whisper: whisper), timing: timing)
    }

    private let english = Locale(identifier: "en_US")

    @Test("a short command has no live guesses, only the final text once the audio ends")
    func shortCommand() async throws {
        let whisper = FakeWhisper { _ in "open safari" }
        let all = try await collect(recognizer(whisper).transcribe(speech(seconds: 0.8), locale: english))
        #expect(all == [Transcript(text: "open safari", isFinal: true)])
        #expect(whisper.calls.count == 1)
    }

    @Test("a longer one shows a revisable guess about every second, and then the final text")
    func guesses() async throws {
        let whisper = FakeWhisper()
        let all = try await collect(recognizer(whisper).transcribe(speech(seconds: 3.5), locale: english))
        #expect(all.map(\.text) == ["heard 1 seconds", "heard 2 seconds", "heard 3 seconds", "heard 4 seconds"])
        #expect(all.map(\.isFinal) == [false, false, false, true])
        #expect(whisper.calls.map(\.seconds).map { Int($0.rounded()) } == [1, 2, 3, 4])
    }

    @Test("a guess that says the same thing again is not repeated")
    func noRepeats() async throws {
        let whisper = FakeWhisper { _ in "same words" }
        let all = try await collect(recognizer(whisper).transcribe(speech(seconds: 3.5), locale: english))
        #expect(all.map(\.text) == ["same words", "same words"])
        #expect(all.map(\.isFinal) == [false, true], "one guess, then the final")
    }

    @Test("silence is never sent to Whisper, which would make words up, and ends as an empty final transcript")
    func silence() async throws {
        let whisper = FakeWhisper { _ in "Thank you for watching!" }
        let all = try await collect(recognizer(whisper).transcribe(speech(seconds: 3, amplitude: 0.0005), locale: english))
        #expect(all == [Transcript(text: "", isFinal: true)])
        #expect(whisper.calls.isEmpty)
    }

    @Test("a click shorter than a syllable is not transcribed either")
    func blip() async throws {
        let whisper = FakeWhisper()
        let all = try await collect(recognizer(whisper).transcribe(speech(seconds: 0.1), locale: english))
        #expect(all == [Transcript(text: "", isFinal: true)] && whisper.calls.isEmpty)
    }

    @Test("what Whisper writes for a sound that isn't speech is removed")
    func annotations() async throws {
        for raw in ["[BLANK_AUDIO]", "(music)", "♪♪", "*sighs*", "[Music] (applause)"] {
            let whisper = FakeWhisper { _ in raw }
            let all = try await collect(recognizer(whisper).transcribe(speech(seconds: 0.8), locale: english))
            #expect(all == [Transcript(text: "", isFinal: true)], "\(raw)")
        }
        let mixed = FakeWhisper { _ in "[Music] open the door (pause) please ♪" }
        let text = try await collect(recognizer(mixed).transcribe(speech(seconds: 0.8), locale: english)).last?.text
        #expect(text == "open the door please")
    }

    @Test("an English-only model is always asked for English; another follows the recognition language")
    func language() async throws {
        let english = FakeWhisper()
        _ = try await collect(
            recognizer(english, model: "base.en").transcribe(speech(seconds: 0.8), locale: Locale(identifier: "hi_IN")))
        #expect(english.calls.first?.language == "en")

        let hindi = FakeWhisper()
        _ = try await collect(
            recognizer(hindi, model: "base").transcribe(speech(seconds: 0.8), locale: Locale(identifier: "hi_IN")))
        #expect(hindi.calls.first?.language == "hi")

        #expect(WhisperRecognizer.language(model: "tiny", locale: Locale(identifier: "und")) == nil)
    }

    @Test("without the model on this Mac, the stream ends with the error that says how to fix it")
    func missingModel() async {
        do {
            _ = try await collect(recognizer(nil, model: "small.en").transcribe(speech(seconds: 1), locale: english))
            Issue.record("expected an error")
        } catch let error as SpeechError {
            #expect(error == .whisperModelMissing(name: "small.en"))
            #expect(error.userFacing.recovery == .openAppSettings)
            #expect(error.userFacing.detail.contains("small.en"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("a failure inside Whisper is reported in words, and a speech error passes through unchanged")
    func failures() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "the model fell over" } }
        do {
            _ = try await collect(recognizer(FakeWhisper { _ in throw Boom() }).transcribe(speech(seconds: 0.8), locale: english))
            Issue.record("expected an error")
        } catch let error as SpeechError {
            #expect(error == .whisperFailed("the model fell over"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        do {
            _ = try await collect(
                recognizer(FakeWhisper { _ in throw SpeechError.recognizerUnavailable }).transcribe(
                    speech(seconds: 0.8), locale: english))
            Issue.record("expected an error")
        } catch let error as SpeechError {
            #expect(error == .recognizerUnavailable)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("past the live limit the guesses stop, but the final text still covers everything said")
    func longSpeech() async throws {
        let whisper = FakeWhisper()
        var timing = WhisperRecognizer.Timing()
        timing.maxPartialAudio = 5
        let all = try await collect(recognizer(whisper, timing: timing).transcribe(speech(seconds: 9), locale: english))
        #expect(all.filter { !$0.isFinal }.count == 5, "guesses at 1, 2, 3, 4 and 5 seconds, and none after")
        #expect(all.last?.isFinal == true && all.last?.text == "heard 9 seconds")
    }

    @Test("an error in the audio itself ends the stream with that error")
    func audioFailure() async {
        struct MicrophoneGone: Error, Equatable {}
        let audio = AsyncThrowingStream<AudioChunk, any Error> { continuation in
            continuation.yield(AudioChunk(samples: [Float](repeating: 0.2, count: 1_600), startTime: 0))
            continuation.finish(throwing: MicrophoneGone())
        }
        do {
            _ = try await collect(recognizer(FakeWhisper()).transcribe(audio, locale: english))
            Issue.record("expected an error")
        } catch let error as MicrophoneGone {
            #expect(error == MicrophoneGone())
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("when the consumer goes away, listening stops")
    func cancellation() async throws {
        let whisper = FakeWhisper()
        let terminated = AsyncGate()
        let audio = AsyncThrowingStream<AudioChunk, any Error> { continuation in
            continuation.onTermination = { _ in Task { await terminated.open() } }
            continuation.yield(AudioChunk(samples: [Float](repeating: 0.2, count: 1_600), startTime: 0))
            // never finishes: a microphone that is still open
        }
        let task = Task { try await collect(recognizer(whisper).transcribe(audio, locale: english)) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = try? await task.value
        await terminated.wait()  // the audio stream was let go, which is what stops the microphone
    }

    @Test("Whisper needs no Speech Recognition permission, and preparing loads the model or says it is missing")
    func permissionsAndPrepare() async throws {
        let transcribers = FakeTranscribers(whisper: FakeWhisper())
        let ready = WhisperRecognizer(model: "base.en", transcribers: transcribers)
        #expect(await ready.requiredPermissions(locale: english).isEmpty)
        try await ready.prepare(locale: english)
        #expect(transcribers.requested.models == ["base.en"])

        let missing = WhisperRecognizer(model: "small", transcribers: FakeTranscribers(whisper: nil))
        await #expect(throws: SpeechError.whisperModelMissing(name: "small")) { try await missing.prepare(locale: english) }
    }
}

@Suite("Whisper text and choices")
struct WhisperTextTests {
    @Test("sound annotations, notes and stray spaces are removed; the words are kept exactly")
    func cleaning() {
        #expect(WhisperText.clean("  open   Safari \n please ") == "open Safari please")
        #expect(WhisperText.clean("[BLANK_AUDIO]").isEmpty)
        #expect(WhisperText.clean("what (uh) time is it? ♪") == "what time is it?")
        #expect(WhisperText.clean("It's 5 o'clock — really.") == "It's 5 o'clock — really.")
        #expect(WhisperText.clean("").isEmpty)
    }

    @Test("the peak is the loudest sample, whichever way it points")
    func peak() {
        #expect(WhisperText.peak([0.1, -0.5, 0.3]) == 0.5)
        #expect(WhisperText.peak([]) == 0)
    }

    @Test("the catalog offers a default that exists, a model per name, and the right one for a language")
    func catalog() {
        #expect(WhisperModelCatalog.model(WhisperModelCatalog.defaultID) != nil)
        #expect(Set(WhisperModelCatalog.all.map(\.id)).count == WhisperModelCatalog.all.count)
        #expect(WhisperModelCatalog.model("base.en")?.folderName == "openai_whisper-base.en")
        #expect(WhisperModelCatalog.model("tiny")?.isEnglishOnly == false)
        #expect(WhisperModelCatalog.all.filter(\.isEnglishOnly).allSatisfy { $0.id.hasSuffix(".en") })
        #expect(WhisperModelCatalog.recommendedID(for: Locale(identifier: "en_GB")) == "base.en")
        #expect(WhisperModelCatalog.recommendedID(for: Locale(identifier: "fr_FR")) == "base")
        #expect(WhisperModelCatalog.model("large-v3") == nil)
    }

    @Test("a model name Voxa doesn't offer is replaced by the default when settings are read")
    func settingsDecoding() throws {
        let odd = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"speechEngine":"whisper","whisperModel":"gigantic"}"#.utf8))
        #expect(odd.speechEngine == .whisper && odd.whisperModel == WhisperModelCatalog.defaultID)
        let good = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"whisperModel":"small"}"#.utf8))
        #expect(good.whisperModel == "small")
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"speechEngine":"appleClassic"}"#.utf8))
        #expect(old.whisperModel == WhisperModelCatalog.defaultID, "settings from before Whisper still load")
    }

    @Test("the provider gives the classic recognizer when Whisper is chosen but not available, and Whisper when it is")
    func provider() {
        struct Marker: SpeechRecognizer {
            func requiredPermissions(locale: Locale) async -> Set<PermissionKind> { [] }
            func prepare(locale: Locale) async throws {}
            func transcribe(_ audio: AsyncThrowingStream<AudioChunk, any Error>, locale: Locale) -> AsyncThrowingStream<
                Transcript, any Error
            > {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let settings = AppSettings(speechEngine: .whisper)
        #expect(DefaultSpeechRecognizerProvider().recognizer(for: settings) is SFSpeechRecognizerEngine)
        #expect(DefaultSpeechRecognizerProvider(whisper: { _ in Marker() }).recognizer(for: settings) is Marker)
        #expect(
            DefaultSpeechRecognizerProvider(whisper: { _ in Marker() }).recognizer(for: AppSettings(speechEngine: .appleClassic))
                is SFSpeechRecognizerEngine)
    }
}
