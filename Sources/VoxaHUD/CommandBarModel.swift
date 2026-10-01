import Observation
import VoxaCore

/// What the Voxa bar's field and microphone show and do: a field to type a command in, and a microphone button to click, talk to, and
/// click again to send. (What Voxa says and asks below them is `HUDModel`; the bar draws both.)
///
/// The model only holds the state and forwards the actions; the app decides what they mean (`onSubmit` carries the command out,
/// `onMicrophone` starts or ends listening, `onClose` puts everything away), so the bar can be tested and drawn without the app.
@MainActor
@Observable
public final class CommandBarModel {
    /// What is typed in the field.
    public var text = ""
    /// A line that says why something didn't happen. Cleared by typing or a new try.
    public var note: String?
    /// Whether the person has the bar open (the shortcut, the menu) and so it is theirs to type in and click, rather than only showing
    /// what a command is doing. The field and the microphone button are there only then.
    public var isOpen = true
    /// Counts up each time the field should take keyboard focus.
    public private(set) var focusRequests = 0

    /// A warning to show under the field (full control is on), asked for each time the bar is drawn so that it follows the setting.
    @ObservationIgnored public var warning: @MainActor () -> String? = { nil }
    /// Carries out a typed command. False when it can't be taken now (Voxa is busy).
    @ObservationIgnored public var onSubmit: (@MainActor (String) -> Bool)?
    /// The microphone button was clicked: start listening, or, if it is listening, send what was said.
    @ObservationIgnored public var onMicrophone: (@MainActor () -> Void)?
    /// Esc, or the close button: put everything away, and let go of the microphone.
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
    public func microphoneClicked() {
        note = nil
        onMicrophone?()
    }

    /// Esc in the field.
    public func escape() {
        onClose?()
    }

    /// Asks for the field to take keyboard focus (the bar was just opened).
    public func requestFocus() {
        focusRequests += 1
    }

    /// Forgets what was typed, for a bar that has been put away.
    public func reset() {
        text = ""
        note = nil
    }

    // MARK: What the bar says

    /// The lines under the field while nothing is going on, most important first: why something didn't happen, then what full
    /// control changes.
    public var lines: [Line] {
        var lines: [Line] = []
        if let note { lines.append(Line(text: note, tone: .plain)) }
        if let warning = warning() { lines.append(Line(text: warning, tone: .warning)) }
        return lines
    }

    public struct Line: Equatable, Sendable {
        public enum Tone: Sendable { case plain, warning }

        public var text: String
        public var tone: Tone

        public init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }
}
