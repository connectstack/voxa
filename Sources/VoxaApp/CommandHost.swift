import Foundation

/// Whether Voxa is free to take a command that no key was held for, or has something that needs it.
public enum SessionAvailability: Equatable, Sendable {
    /// Nothing is happening. A command can be taken.
    case ready
    /// The microphone is the person's: a held key or the microphone button has it, or what it heard is still being turned into a command.
    case listening
    /// A command is being carried out: thinking, acting, or asking whether it may.
    case working
    /// Voxa is speaking.
    case speaking
}

/// What the Voxa bar's field and Siri need of the session: whether Voxa is free, and a way to give it a command that no key was held for.
@MainActor
public protocol CommandHost: AnyObject {
    var availability: SessionAvailability { get }

    /// Carries out `command` exactly as one that was held-to-talk. False when Voxa isn't free to take it.
    @discardableResult
    func submitCommand(_ command: String) -> Bool
}
