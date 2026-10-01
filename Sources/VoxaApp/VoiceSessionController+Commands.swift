import Foundation
import VoxaCore
import VoxaHUD

/// Commands that no key was held for: the one typed in the Voxa bar, and the one Siri hands over.
extension VoiceSessionController: CommandHost {
    /// Whether a command can be taken: only when nothing is being recorded, carried out or said.
    public var availability: SessionAvailability {
        switch phase {
        case .starting, .listening, .finalizing: return .listening
        case .idle, .failed: break
        }
        if agentTask != nil { return .working }
        if speaker?.isSpeaking == true { return .speaking }
        return .ready
    }

    /// Carries out a command that was given without the key (typed, or handed over by Siri), exactly as one that was held-to-talk:
    /// the agent, its policy and its confirmations are the same. False when Voxa isn't free to take it.
    @discardableResult
    public func submitCommand(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, availability == .ready, let agent else { return false }
        errorResetTask?.cancel()
        disarmDismiss()
        lastError = nil
        phase = .idle
        hud.hotkeyHint = hotkeys.pushToTalkDescription
        hud.beginSession()
        hud.setTranscript(text, isFinal: true)
        Log.session.info("a command was given without the key (\(text.count) characters)")
        startAgent(agent, command: text)
        return true
    }
}
