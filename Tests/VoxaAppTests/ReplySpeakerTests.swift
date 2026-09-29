import Foundation
import Testing
@testable import VoxaApp
import VoxaCore
import VoxaHUD
import VoxaTestSupport
import VoxaVoice

@MainActor
@Suite("ReplySpeaker")
struct ReplySpeakerTests {
    private let synthesizer = FakeSpeaker()
    private let settings = FakeSettings(AppSettings(localeIdentifier: "en_IN"))
    private let speaker: ReplySpeaker

    private let prompt = ConfirmationPrompt(
        toolName: "run_applescript", title: "Run an AppleScript", summary: "Runs a script.", risk: .sensitive
    )

    init() {
        speaker = ReplySpeaker(synthesizer: synthesizer, settings: settings)
    }

    @Test("a reply is spoken in the recognition language, at the chosen pace, with the best voice by default")
    func reply() {
        settings.current.speechRate = 0.6
        speaker.speakReply("Opened Safari.")
        #expect(synthesizer.spoken == [
            FakeSpeaker.Utterance(text: "Opened Safari.", options: SpeechOptions(voiceIdentifier: nil, language: "en_IN", rate: 0.6))
        ])
    }

    @Test("a voice chosen in Settings is the one used")
    func chosenVoice() {
        settings.current.voiceIdentifier = "com.apple.voice.premium.en-US.Zoe"
        speaker.speakReply("Hello.")
        #expect(synthesizer.spoken.first?.options.voiceIdentifier == "com.apple.voice.premium.en-US.Zoe")
    }

    @Test("with spoken replies off, nothing is said: not a reply, not an error, not a question")
    func off() {
        settings.current.speakReplies = false
        speaker.speakReply("Opened Safari.")
        speaker.speakError(UserFacingError(title: "Ollama isn't running", detail: "Open it."))
        speaker.speakQuestion(prompt)
        #expect(synthesizer.spoken.isEmpty)
    }

    @Test("an error is spoken as its short title, not its detail")
    func error() {
        speaker.speakError(UserFacingError(title: "Ollama isn't running", detail: "Open the Ollama app, then try again."))
        #expect(synthesizer.lastText == "Ollama isn't running")
    }

    @Test("a confirmation is put as a question, telling the person how to answer")
    func question() {
        speaker.speakQuestion(prompt)
        #expect(synthesizer.lastText == "Run an AppleScript? Hold the shortcut and say yes or no.")
    }

    @Test("the test button speaks its sample even when replies are off, because the person asked")
    func sample() {
        settings.current.speakReplies = false
        speaker.speakSample()
        #expect(synthesizer.lastText == L10n.VoiceSpoken.sample)
    }

    @Test("stopping stops the synthesizer, and the voices come from the system")
    func stopAndVoices() {
        speaker.speakReply("A long answer.")
        #expect(speaker.isSpeaking)
        speaker.stop()
        #expect(!speaker.isSpeaking && synthesizer.stopCount == 1)
        #expect(speaker.voices() == synthesizer.installedVoices)
    }
}
