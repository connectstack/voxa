import Foundation
import Speech
import Testing
import VoxaCore
@testable import VoxaSpeech
import VoxaTestSupport

/// An engine that says which one it is, so a test can tell which was used.
private struct NamedRecognizer: SpeechRecognizer {
    let name: String
    var permissions: Set<PermissionKind> = []

    func requiredPermissions(locale: Locale) async -> Set<PermissionKind> { permissions }
    func prepare(locale: Locale) async throws {}

    func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        let name = name
        return AsyncThrowingStream { continuation in
            continuation.yield(Transcript(text: name, isFinal: true))
            continuation.finish()
        }
    }
}

@Suite("OnlineSpeechRecognizer")
struct OnlineSpeechRecognizerTests {
    private let locale = Locale(identifier: "en_IN")
    private let audio = AsyncThrowingStream<AudioChunk, any Error>.of([])

    private func text(_ recognizer: OnlineSpeechRecognizer) async throws -> String {
        var last = ""
        for try await transcript in recognizer.transcribe(audio, locale: locale) { last = transcript.text }
        return last
    }

    @Test("with a network the voice goes to the online engine")
    func online() async throws {
        let recognizer = OnlineSpeechRecognizer(
            online: NamedRecognizer(name: "online"),
            fallback: NamedRecognizer(name: "on this Mac"),
            isOnline: { true }
        )
        #expect(try await text(recognizer) == "online")
    }

    @Test("with no network it is recognized on this Mac instead, rather than failing")
    func offline() async throws {
        let recognizer = OnlineSpeechRecognizer(
            online: NamedRecognizer(name: "online"),
            fallback: NamedRecognizer(name: "on this Mac"),
            isOnline: { false }
        )
        #expect(try await text(recognizer) == "on this Mac")
    }

    @Test("the network is looked at each time the audio starts, so a connection that comes back is used")
    func lookedAtEachTime() async throws {
        let box = OnlineBox()
        let recognizer = OnlineSpeechRecognizer(
            online: NamedRecognizer(name: "online"),
            fallback: NamedRecognizer(name: "on this Mac"),
            isOnline: { box.value }
        )
        box.value = false
        #expect(try await text(recognizer) == "on this Mac")
        box.value = true
        #expect(try await text(recognizer) == "online")
    }

    @Test("the permission asked for before the microphone opens is the online engine's, even when it ends up offline")
    func permissions() async {
        let recognizer = OnlineSpeechRecognizer(
            online: NamedRecognizer(name: "online", permissions: [.speechRecognition]),
            fallback: NamedRecognizer(name: "on this Mac"),
            isOnline: { false }
        )
        #expect(await recognizer.requiredPermissions(locale: locale) == [.speechRecognition])
    }
}

private final class OnlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = true
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

@Suite("SFSpeechRecognizerEngine: where the voice is recognized")
struct SFSpeechRecognizerEngineRecognitionTests {
    @Test("an on-device request is told to stay on this Mac, and an online one is not")
    func requests() {
        let local = SFSpeechAudioBufferRecognitionRequest()
        SFSpeechSession.configure(local, onDevice: true)
        #expect(local.requiresOnDeviceRecognition, "this is what keeps the voice from going to Apple's servers")
        #expect(local.shouldReportPartialResults)

        let remote = SFSpeechAudioBufferRecognitionRequest()
        SFSpeechSession.configure(remote, onDevice: false)
        #expect(!remote.requiresOnDeviceRecognition)
        #expect(remote.shouldReportPartialResults, "the live words show either way")
    }

    @Test("the engine is on-device unless it is built to be online")
    func defaultsToOnDevice() async {
        // Needs Speech Recognition permission to go further, which a test run has not been granted; what is checked is what it asks for.
        let locale = Locale(identifier: "en_US")
        #expect(await SFSpeechRecognizerEngine().requiredPermissions(locale: locale) == [.speechRecognition])
        #expect(await SFSpeechRecognizerEngine(recognition: .online).requiredPermissions(locale: locale) == [.speechRecognition])
    }
}
