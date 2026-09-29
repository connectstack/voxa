import AVFoundation
import Foundation
import Testing
import VoxaCore
@testable import VoxaVoice

/// These use the system's real speech synthesizer, but render to memory instead of playing, so they need no speakers and
/// disturb no one. They prove that a voice exists and produces sound, which no fake could.
@MainActor
@Suite("AVFoundationSpeaker", .serialized)
struct AVFoundationSpeakerTests {
    @Test("the system has at least one voice, and each has a name, a language and an identifier")
    func voicesExist() {
        let voices = AVFoundationSpeaker().voices()
        #expect(!voices.isEmpty)
        for voice in voices {
            #expect(!voice.id.isEmpty && !voice.name.isEmpty && !voice.language.isEmpty)
        }
    }

    @Test("a real voice really produces sound for a sentence")
    func rendersAudio() async {
        let (samples, sampleRate) = await AVFoundationSpeaker.render(
            "Hello, I am Voxa.", options: SpeechOptions(language: "en_US", rate: AppSettings.defaultSpeechRate)
        )
        #expect(sampleRate > 8_000)
        #expect(samples.count > Int(sampleRate * 0.5), "a sentence lasts at least half a second, got \(samples.count) samples")
        let peak = samples.map(abs).max() ?? 0
        #expect(peak > 0.01, "the audio isn't silent (peak \(peak))")
    }

    @Test("a faster rate makes a shorter recording of the same words")
    func rateChangesLength() async {
        let text = "This sentence is here to be timed at two different speeds."
        let slow = await AVFoundationSpeaker.render(text, options: SpeechOptions(language: "en_US", rate: 0.35))
        let fast = await AVFoundationSpeaker.render(text, options: SpeechOptions(language: "en_US", rate: 0.65))
        #expect(!slow.samples.isEmpty && !fast.samples.isEmpty)
        #expect(Double(fast.samples.count) / fast.sampleRate < Double(slow.samples.count) / slow.sampleRate)
    }

    @Test("the voice chosen for a language really is one of that language")
    func voiceMatchesLanguage() {
        let voice = AVFoundationSpeaker.voice(for: SpeechOptions(language: "en_US"))
        #expect(voice?.language.hasPrefix("en") == true)
    }

    @Test("a rate outside what is offered is brought back into range")
    func rateClamped() {
        let low = AVFoundationSpeaker.utterance("x", options: SpeechOptions(rate: -5))
        let high = AVFoundationSpeaker.utterance("x", options: SpeechOptions(rate: 9))
        #expect(Double(low.rate) >= AppSettings.speechRateRange.lowerBound - 0.001)
        #expect(Double(high.rate) <= AppSettings.speechRateRange.upperBound + 0.001)
    }

    @Test("speaking nothing does nothing, and stop is safe with nothing to stop")
    func nothingToSay() {
        let speaker = AVFoundationSpeaker()
        speaker.speak("   ", options: SpeechOptions())
        speaker.speak("**", options: SpeechOptions())
        #expect(!speaker.isSpeaking)
        speaker.stop()
        speaker.stop()
        #expect(!speaker.isSpeaking)
    }
}
