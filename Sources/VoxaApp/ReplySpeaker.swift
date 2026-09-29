import Foundation
import VoxaCore
import VoxaVoice

/// Decides what is said aloud and how, from what the user has chosen in Settings.
///
/// Three things are spoken: the agent's reply, the title of an error, and the question of a confirmation. Everything that is
/// spoken is also on screen, so speech is never the only way to learn something. Any new press of the shortcut, and Esc, stop
/// it at once: the microphone must never hear Voxa's own voice as the next command.
@MainActor
public final class ReplySpeaker {
    private let synthesizer: any SpeechSynthesizing
    private let settings: any SettingsProviding

    public init(synthesizer: any SpeechSynthesizing, settings: any SettingsProviding) {
        self.synthesizer = synthesizer
        self.settings = settings
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    /// The voices the system offers, for the picker in Settings.
    public func voices() -> [VoiceInfo] { synthesizer.voices() }

    /// Says the agent's reply, if the user wants replies spoken.
    public func speakReply(_ text: String) {
        guard settings.current.speakReplies else { return }
        say(text)
    }

    /// Says what went wrong, in a few words.
    public func speakError(_ error: UserFacingError) {
        guard settings.current.speakReplies else { return }
        say(error.title)
    }

    /// Says a confirmation's question, so it can be answered without looking at the screen.
    public func speakQuestion(_ prompt: ConfirmationPrompt) {
        guard settings.current.speakReplies else { return }
        say(L10n.VoiceSpoken.question(prompt.title))
    }

    /// The sentence behind Settings' "Test voice" button. It speaks even if replies are switched off, since the person asked.
    public func speakSample() {
        say(L10n.VoiceSpoken.sample)
    }

    public func stop() {
        synthesizer.stop()
    }

    private func say(_ text: String) {
        let current = settings.current
        synthesizer.speak(
            text,
            options: SpeechOptions(
                voiceIdentifier: current.voiceIdentifier.isEmpty ? nil : current.voiceIdentifier,
                language: current.localeIdentifier,
                rate: current.speechRate
            )
        )
    }
}
