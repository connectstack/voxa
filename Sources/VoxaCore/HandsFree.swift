import Foundation

/// Whether Voxa is free for its microphone to listen, or has something else that needs it.
public enum HandsFreeAvailability: Equatable, Sendable {
    /// Nothing is happening. The microphone can listen.
    case ready
    /// The shortcut is held, or was and its audio is still being turned into a command. That has the microphone.
    case pushToTalk
    /// A command is being carried out: thinking, acting, or asking whether it may.
    case working
    /// Voxa is speaking, and the microphone would hear it.
    case speaking
}

/// What continuous listening (the microphone button in the Voxa bar) is doing, for the bar, Settings and the menu bar to say.
public enum HandsFreeState: Equatable, Sendable {
    /// Not listening.
    case off
    /// Getting permission, or the microphone.
    case starting
    /// The microphone is open: what is said is taken as a command.
    case listening
    /// It is switched on, but the microphone is closed because Voxa is busy with something else.
    case paused(HandsFreeAvailability)
    /// It can't listen (no permission, no microphone), and will keep trying.
    case unavailable(UserFacingError)

    /// Whether it is switched on and working, or getting there: the bar shows its microphone as live.
    public var isOn: Bool {
        switch self {
        case .starting, .listening, .paused, .unavailable: true
        case .off: false
        }
    }

    /// Whether the microphone is open (or being opened) right now.
    public var isListening: Bool {
        switch self {
        case .starting, .listening: true
        case .off, .paused, .unavailable: false
        }
    }
}

/// Why continuous listening switched itself off.
public enum HandsFreeStopReason: Equatable, Sendable {
    /// Nothing was said for as long as Settings allows, so the microphone was let go.
    case idle(minutes: Int)
}
