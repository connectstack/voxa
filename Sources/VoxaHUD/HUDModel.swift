import Observation
import VoxaCore

/// What the HUD is showing.
public enum HUDMode: Equatable, Sendable {
    /// The microphone is starting.
    case preparing
    case listening
    /// The key was released; speech-to-text is finishing.
    case transcribing
    /// The recognized command.
    case result(String)
    /// A gentle, non-error message such as "I didn't catch that".
    case notice(title: String, detail: String?)
    case error(UserFacingError)
    /// The model is working. `partial` is what it has said so far, if anything.
    case thinking(partial: String?)
    /// A tool is running; `title` says what ("Open Safari").
    case acting(title: String)
    /// Waiting for the user to allow or decline an action.
    case confirm(ConfirmationPrompt)
    /// The agent's final reply.
    case reply(String)

    /// Whether clicks must reach the HUD (a button is showing) rather than pass through it.
    public var isInteractive: Bool {
        switch self {
        case .error(let error): error.recovery != nil
        case .confirm: true
        default: false
        }
    }

    /// Whether the microphone meter is meaningful in this mode.
    var showsMeter: Bool {
        switch self {
        case .preparing, .listening: true
        default: false
        }
    }

    var showsTranscript: Bool {
        switch self {
        case .preparing, .listening, .transcribing, .result, .thinking, .acting: true
        case .notice, .error, .confirm, .reply: false
        }
    }

    var showsCancelHint: Bool {
        switch self {
        case .preparing, .listening, .transcribing, .thinking, .acting: true
        default: false
        }
    }
}

/// What the user chose in a confirmation.
public enum ConfirmationChoice: Sendable, Equatable {
    case allow
    case deny
}

/// The state of answering a confirmation by voice, shown under the buttons.
public enum AnswerStatus: Sendable, Equatable {
    /// Nothing yet; the hint says how to answer.
    case idle
    /// The microphone is open for an answer.
    case listening
    /// What was heard wasn't a clear yes or no.
    case unclear
}

/// View state for the HUD. `@Observable` so SwiftUI re-renders only the views that read a changed property; the
/// meter reads `levels` alone, so ~45 level updates per second never re-lay-out the transcript.
@MainActor
@Observable
public final class HUDModel {
    /// Number of bars in the level meter.
    public static let barCount = 28

    public var mode: HUDMode = .preparing
    public var transcript = ""
    public var isTranscriptFinal = false
    /// The push-to-talk shortcut, e.g. "⌥Space", shown in hints.
    public var hotkeyHint: String?
    /// Whether the keyboard (Return) can answer the current confirmation yet. Off for a moment after a prompt appears, so
    /// a stray keystroke can't approve it.
    public var confirmationKeysEnabled = false
    public var answerStatus: AnswerStatus = .idle
    /// Newest level last; a scrolling history drawn as the meter.
    public private(set) var levels = [Float](repeating: 0, count: HUDModel.barCount)

    @ObservationIgnored public var onRecovery: ((RecoveryAction) -> Void)?
    @ObservationIgnored public var onConfirmationChoice: ((ConfirmationChoice) -> Void)?

    public init() {}

    public func push(level: AudioLevel) {
        levels.removeFirst()
        levels.append(level.rms)
    }

    /// Clears everything tied to the previous command.
    public func resetSession() {
        transcript = ""
        isTranscriptFinal = false
        confirmationKeysEnabled = false
        answerStatus = .idle
        levels = [Float](repeating: 0, count: Self.barCount)
    }
}

/// What the session coordinator needs from the HUD. A protocol so tests can record calls and the coordinator never
/// touches AppKit.
@MainActor
public protocol HUDPresenting: AnyObject {
    var hotkeyHint: String? { get set }
    var onRecovery: ((RecoveryAction) -> Void)? { get set }
    /// Called when the user answers a confirmation with a button.
    var onConfirmationChoice: ((ConfirmationChoice) -> Void)? { get set }

    /// Starts a new command: clears the previous transcript and meter and shows the HUD.
    func beginSession()
    func show(_ mode: HUDMode)
    func setTranscript(_ text: String, isFinal: Bool)
    func push(level: AudioLevel)
    /// Turns the keyboard answer for the current confirmation on or off (it is off during the input guard).
    func setConfirmationKeysEnabled(_ enabled: Bool)
    /// Shows the progress of a spoken answer to the current confirmation.
    func setAnswerStatus(_ status: AnswerStatus)
    /// Hides the HUD, immediately or after `delay`. Any later `show` cancels a pending hide.
    func hide(after delay: Duration?)
}
