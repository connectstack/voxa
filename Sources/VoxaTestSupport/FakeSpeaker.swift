import Foundation
import VoxaVoice

/// A synthesizer that says nothing and remembers what it was asked to say.
@MainActor
public final class FakeSpeaker: SpeechSynthesizing {
    public struct Utterance: Equatable {
        public var text: String
        public var options: SpeechOptions

        public init(text: String, options: SpeechOptions) {
            self.text = text
            self.options = options
        }
    }

    public private(set) var spoken: [Utterance] = []
    public private(set) var stopCount = 0
    public private(set) var isSpeaking = false
    public var installedVoices: [VoiceInfo] = [
        VoiceInfo(id: "test.voice.en", name: "Test", language: "en-US", quality: .enhanced)
    ]

    public init() {}

    public func speak(_ text: String, options: SpeechOptions) {
        spoken.append(Utterance(text: text, options: options))
        isSpeaking = true
    }

    public func stop() {
        stopCount += 1
        isSpeaking = false
    }

    public func voices() -> [VoiceInfo] { installedVoices }

    /// What was said last.
    public var lastText: String? { spoken.last?.text }

    /// The speech ends by itself, as it does when the last word is out.
    public func finish() { isSpeaking = false }
}
