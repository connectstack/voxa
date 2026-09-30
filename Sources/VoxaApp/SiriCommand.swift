import Foundation

/// What came of handing Voxa a command from Siri.
public enum SiriCommandOutcome: Sendable, Equatable {
    /// Voxa took it and is working on it.
    case started
    /// Voxa is in the middle of something (a held key, a command, a reply being spoken): try again in a moment.
    case busy
    /// There was nothing to do, or Voxa isn't running.
    case nothing
}

/// Commands that Siri hears instead of Voxa.
///
/// "Hey Siri, ask Voxa" makes Siri listen and turn the speech into text; Voxa's App Intent hands that text here. From this point it
/// is a command like any other, exactly as if it had been held-to-talk: the same agent, the same policy, the same refusals, and the
/// same Allow cards. Nothing that Siri hears can approve one; a question waits for a click, the shortcut chord, or the key held.
/// Voxa itself opens no microphone for this and needs no speech recognition, since Siri did the listening.
@MainActor
public enum SiriCommand {
    /// Hands `text` to Voxa as a command.
    public static func run(_ text: String, on host: any HandsFreeHost) -> SiriCommandOutcome {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .nothing }
        guard host.handsFreeAvailability == .ready else { return .busy }
        return host.submitCommand(command) ? .started : .busy
    }

    /// From an App Intent, which the system may have started Voxa to run: waits for the app to be up, then hands it over.
    public static func run(_ text: String, waitingUpTo timeout: Duration = .seconds(8)) async -> SiriCommandOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while AppEnvironment.current == nil, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(100))
        }
        guard let environment = AppEnvironment.current else { return .nothing }
        return run(text, on: environment.session)
    }
}
