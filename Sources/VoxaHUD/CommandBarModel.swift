import Observation
import VoxaCore

/// What the Voxa bar's field and microphone show and do: a field to type a command in, and a microphone button that listens
/// continuously. (What Voxa says and asks below them is `HUDModel`; the bar draws both.)
///
/// The model only holds the state and forwards the actions; the app decides what they mean (`onSubmit` carries the command out,
/// `onToggleListening` switches the microphone, `onClose` puts everything away), so the bar can be tested and drawn without the app.
@MainActor
@Observable
public final class CommandBarModel {
    /// What is typed in the field.
    public var text = ""
    /// What continuous listening is doing: the microphone button shows it.
    public var listening: HandsFreeState = .off
    /// A line that says why something didn't happen, or that listening stopped. Cleared by typing or a new try.
    public var note: String?
    /// Whether the person has the bar open (the shortcut, the menu, the microphone) and so it is theirs to type in and click, rather
    /// than only showing what a command is doing. The field and the microphone button are there only then.
    public var isOpen = true
    /// Counts up each time the field should take keyboard focus.
    public private(set) var focusRequests = 0

    /// A warning to show while the bar is listening (full control is on), asked for each time the bar is drawn so that it follows
    /// the setting.
    @ObservationIgnored public var warning: @MainActor () -> String? = { nil }
    /// Carries out a typed command. False when it can't be taken now (Voxa is busy).
    @ObservationIgnored public var onSubmit: (@MainActor (String) -> Bool)?
    @ObservationIgnored public var onToggleListening: (@MainActor () -> Void)?
    /// Esc, or the close button: put everything away, and stop listening.
    @ObservationIgnored public var onClose: (@MainActor () -> Void)?

    public init() {}

    /// Return in the field.
    public func submit() {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        note = nil
        if onSubmit?(command) == true {
            text = ""
        } else {
            note = L10n.Bar.busyNote
        }
    }

    /// The microphone button.
    public func toggleListening() {
        note = nil
        onToggleListening?()
    }

    /// Esc in the field.
    public func escape() {
        onClose?()
    }

    /// Asks for the field to take keyboard focus (the bar was just opened).
    public func requestFocus() {
        focusRequests += 1
    }

    /// Forgets what was typed and said, for a bar that has been put away.
    public func reset() {
        text = ""
        note = nil
    }

    // MARK: What the bar says

    /// What the field says while it is empty.
    public var placeholder: String {
        switch listening {
        case .off: L10n.Bar.placeholder
        case .starting: L10n.Bar.placeholderStarting
        case .listening: L10n.Bar.placeholderListening
        case .paused(.speaking): L10n.Bar.placeholderSpeaking
        case .paused: L10n.Bar.placeholderWorking
        case .unavailable(let error): error.title
        }
    }

    /// The lines under the field while nothing is going on, most important first: what stopped it, then either why the microphone
    /// isn't working, or what listening means and what full control changes.
    public var lines: [Line] {
        var lines: [Line] = []
        if let note { lines.append(Line(text: note, tone: .plain)) }
        switch listening {
        case .unavailable(let error):
            lines.append(Line(text: error.detail, tone: .problem))
        case .starting, .listening, .paused:
            lines.append(Line(text: L10n.Bar.listeningNote, tone: .plain))
            if let warning = warning() { lines.append(Line(text: warning, tone: .warning)) }
        case .off:
            break
        }
        return lines
    }

    public struct Line: Equatable, Sendable {
        public enum Tone: Sendable { case plain, warning, problem }

        public var text: String
        public var tone: Tone

        public init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }
}
