import Foundation
import VoxaCore
import VoxaHUD

/// What continuous listening, the Voxa bar and Siri need of the session: whether Voxa is free, and a way to give it a command that
/// no key was held for.
extension VoiceSessionController: HandsFreeHost {
    /// Whether the microphone may be used to listen: only when nothing is being recorded, carried out or said.
    public var handsFreeAvailability: HandsFreeAvailability {
        switch phase {
        case .starting, .listening, .finalizing: return .pushToTalk
        case .idle, .failed: break
        }
        if agentTask != nil { return .working }
        if speaker?.isSpeaking == true { return .speaking }
        return .ready
    }

    /// Carries out a command that was given without the key (typed, said to the microphone, or handed over by Siri), exactly as one
    /// that was held-to-talk: the agent, its policy and its confirmations are the same. False when Voxa isn't free to take it.
    @discardableResult
    public func submitCommand(_ command: String) -> Bool {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, handsFreeAvailability == .ready, let agent else { return false }
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
