import Foundation
import Observation
import VoxaCore

/// What the Voxa bar is showing below its field. (Once the HUD; the bar now carries everything Voxa has to say.)
public enum HUDMode: Equatable, Sendable {
    /// Nothing is going on: the bar is open, waiting for a command to be typed or said.
    case idle
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

    /// Whether clicks must reach the bar (a button is showing) rather than pass through it.
    public var isInteractive: Bool {
        switch self {
        case .error(let error): error.recovery != nil
        case .confirm: true
        default: false
        }
    }

    /// Whether a command is being taken, carried out or asked about, so the bar must not take the keyboard: what the command types
    /// and presses goes to the app in front, and a question must never be answered by a stray keystroke.
    public var isInFlight: Bool {
        switch self {
        case .preparing, .listening, .transcribing, .thinking, .acting, .confirm: true
        case .idle, .result, .notice, .error, .reply: false
        }
    }

    /// Whether the field may be typed into: nothing is under way.
    public var allowsTyping: Bool { !isInFlight }
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

/// What the bar shows below its field. `@Observable` so SwiftUI re-renders only the views that read a changed property; the
/// meter reads `levels` alone, so ~45 level updates per second never re-lay-out the transcript.
@MainActor
@Observable
public final class HUDModel {
    /// Number of bars in the level meter.
    public static let barCount = 80

    public var mode: HUDMode = .idle
    public var transcript = ""
    public var isTranscriptFinal = false
    /// Whether the microphone button's click has Voxa listening (no key is held), so that the command is sent by clicking it again:
    /// the hint under "Listening…" says so instead of telling them which key to release.
    public var endsOnClick = false
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

    /// The least time between two bars of the meter, in seconds. The microphone reports its level about 45 times a second, and drawing
    /// the meter that often is most of what the bar costs while it listens.
    @ObservationIgnored private let levelInterval: TimeInterval
    @ObservationIgnored private let uptime: () -> TimeInterval
    @ObservationIgnored private var lastBarAt = -TimeInterval.infinity
    /// The loudest level since the last bar, so that a short sound between two bars isn't lost.
    @ObservationIgnored private var loudest: Float = 0

    /// - Parameters:
    ///   - levelInterval: The least time between two bars of the meter; none by default, so that each level is a bar.
    ///   - uptime: The time now, in seconds; a test brings its own.
    public init(levelInterval: TimeInterval = 0, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.levelInterval = levelInterval
        self.uptime = uptime
    }

    /// A notice or an error that arrives with no command before it (nothing was heard) says its title where the command would be, so
    /// the bar doesn't show an empty field above it.
    var headline: String? {
        guard transcript.isEmpty else { return nil }
        switch mode {
        case .notice(let title, _): return title
        case .error(let error): return error.title
        default: return nil
        }
    }

    public func push(level: AudioLevel) {
        loudest = max(loudest, min(max(level.rms, 0), 1))
        let now = uptime()
        guard now - lastBarAt >= levelInterval else { return }
        lastBarAt = now
        levels.removeFirst()
        levels.append(loudest)
        loudest = 0
    }

    /// Clears everything tied to the previous command.
    public func resetSession() {
        transcript = ""
        isTranscriptFinal = false
        endsOnClick = false
        confirmationKeysEnabled = false
        answerStatus = .idle
        levels = [Float](repeating: 0, count: Self.barCount)
        loudest = 0
        lastBarAt = -.infinity
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
    /// Says that the microphone button's click has Voxa listening, so the command is sent by clicking it again, rather than by
    /// letting go of a key. Cleared when a new command begins.
    func setListeningEndsOnClick(_ endsOnClick: Bool)
    /// Shows the progress of a spoken answer to the current confirmation.
    func setAnswerStatus(_ status: AnswerStatus)
    /// Hides the HUD, immediately or after `delay`. Any later `show` cancels a pending hide.
    func hide(after delay: Duration?)
}

#if DEBUG
extension HUDModel {
    /// Puts a whole meter in place at once, for the debug states that show one (the meter is otherwise spaced out in time). Debug builds only.
    public func debugFillMeter(_ newLevels: [Float]) {
        let padded = [Float](repeating: 0, count: max(0, Self.barCount - newLevels.count)) + newLevels
        levels = Array(padded.suffix(Self.barCount))
    }
}
#endif

extension HUDPresenting {
    /// Most presenters have nothing to show for it.
    public func setListeningEndsOnClick(_ endsOnClick: Bool) {}
}
