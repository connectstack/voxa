// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The Voxa bar (type a command, or click the microphone and talk) and continuous listening.
extension L10n {
    public enum Bar {
        // MARK: The bar itself

        public static var placeholder: String {
            String(localized: "Type to Voxa", comment: "Placeholder in the Voxa bar's text field")
        }
        public static var placeholderListening: String {
            String(localized: "Listening… say a command", comment: "Placeholder in the Voxa bar while the microphone is listening")
        }
        public static var placeholderWorking: String {
            String(localized: "Working on it…", comment: "Placeholder in the Voxa bar while a command is being carried out")
        }
        public static var placeholderSpeaking: String {
            String(localized: "Speaking…", comment: "Placeholder in the Voxa bar while Voxa is speaking")
        }
        public static var placeholderStarting: String {
            String(localized: "Getting the microphone…", comment: "Placeholder in the Voxa bar while the microphone opens")
        }
        public static var fieldLabel: String {
            String(localized: "Command", comment: "Accessibility label of the Voxa bar's text field")
        }
        public static var startListening: String {
            String(localized: "Start listening", comment: "Label of the microphone button in the Voxa bar while it is off")
        }
        public static var stopListening: String {
            String(localized: "Stop listening", comment: "Label of the microphone button in the Voxa bar while it is on")
        }
        public static var listeningNote: String {
            String(localized: "Listening: everything you say is taken as a command. Esc stops.", comment: "Line under the Voxa bar while the microphone is listening")
        }
        public static var busyNote: String {
            String(localized: "Voxa is busy. Press Esc to stop it.", comment: "Line under the Voxa bar when a command is typed while another is running")
        }
        public static func stoppedIdle(_ minutes: Int) -> String {
            String(localized: "Stopped listening after \(minutes) minutes of silence.", comment: "Line under the Voxa bar when continuous listening switched itself off. The argument is a number of minutes")
        }
        public static var fullControlWarning: String {
            String(localized: "Full control is on: what you say runs without asking.", comment: "Warning under the Voxa bar while the microphone is listening and full control is on")
        }

        // MARK: Settings → General

        public static var section: String {
            String(localized: "Voxa bar", comment: "Settings section title for the bar you can type or talk to")
        }
        public static var shortcut: String {
            String(localized: "Open the Voxa bar", comment: "Settings label for the hotkey recorder that opens the Voxa bar")
        }
        public static var shortcutHelp: String {
            String(
                localized: "Type a command, or click the microphone and Voxa listens until you stop it. Everything it hears while the microphone is on is taken as a command, so switch it off when others are talking. Nothing said aloud can approve an action: a question waits for a click, the shortcut chord, or the push-to-talk key held. macOS shows its orange microphone dot while it listens.",
                comment: "Help under the Voxa bar shortcut in Settings"
            )
        }
        public static var idle: String {
            String(localized: "Stop listening after", comment: "Settings label for how long continuous listening may go with nothing said")
        }
        public static var idleNever: String {
            String(localized: "Never", comment: "Idle choice: continuous listening never switches itself off")
        }
        public static func idleMinutes(_ minutes: Int) -> String {
            String(localized: "\(minutes) minutes of silence", comment: "Idle choice. The argument is a number of minutes")
        }
        public static var idleHelp: String {
            String(localized: "So a microphone that was left on doesn't stay on.", comment: "Help under the idle choice")
        }

        // MARK: Menu bar

        public static func menuOpen(_ shortcut: String?) -> String {
            shortcut.map { String(localized: "Type or Talk to Voxa… (\($0))", comment: "Menu-bar item that opens the Voxa bar. The argument is its shortcut, e.g. ⌥⇧Space") }
                ?? String(localized: "Type or Talk to Voxa…", comment: "Menu-bar item that opens the Voxa bar")
        }
        public static var menuStopListening: String {
            String(localized: "Stop Listening", comment: "Menu-bar item that switches continuous listening off")
        }
        public static var menuListening: String {
            String(localized: "Listening: say a command", comment: "Menu-bar status line while continuous listening is on")
        }
    }
}

// swiftlint:enable line_length
