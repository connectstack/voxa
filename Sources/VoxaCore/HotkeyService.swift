import Foundation

public enum PushToTalkEvent: Sendable, Equatable {
    case pressed
    case released
}

/// Global keyboard shortcuts the session needs. The real implementation lives in VoxaApp (KeyboardShortcuts);
/// tests substitute a fake that emits events on demand.
@MainActor
public protocol HotkeyService: AnyObject {
    /// `.pressed` / `.released` for the user's push-to-talk shortcut. A single consumer is expected.
    var pushToTalk: AsyncStream<PushToTalkEvent> { get }

    /// Registers Esc as a global shortcut for exactly as long as the returned stream is being iterated,
    /// emitting one element per press. Cancelling the consuming task unregisters the key, so Esc keeps working
    /// normally in every other app whenever no session is active.
    func cancelKeyPresses() -> AsyncStream<Void>

    /// Registers ⌘Return as a global shortcut for exactly as long as the returned stream is being iterated, emitting one
    /// element per press. It is used only while a confirmation is showing (and only once its input guard has passed), so
    /// the chord keeps working normally everywhere else.
    ///
    /// It is deliberately a chord, not plain Return: a global shortcut swallows the keys it matches, so a bare Return
    /// typed anywhere (sending a message, say) would approve a pending action by accident. ⌘Return is a deliberate
    /// "confirm" that isn't typed by accident.
    func allowKeyPresses() -> AsyncStream<Void>

    /// Human-readable form of the push-to-talk shortcut, e.g. "⌥Space". `nil` when none is configured.
    var pushToTalkDescription: String? { get }
}

/// Coarse app state shown by the menu-bar icon and read by the feedback layer.
public enum AppStatus: Sendable, Equatable {
    case idle
    case listening
    case thinking
    case acting
    /// Waiting for the user to allow or decline an action.
    case confirming
    case error
}
