// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The Voxa bar: type a command, or click the microphone, talk, and click it again.
extension L10n {
    public enum Bar {
        // MARK: The bar itself

        public static var placeholder: String {
            String(localized: "Type to Voxa", comment: "Placeholder in the Voxa bar's text field")
        }
        public static var fieldLabel: String {
            String(localized: "Command", comment: "Accessibility label of the Voxa bar's text field")
        }
        public static var microphoneStart: String {
            String(localized: "Talk to Voxa", comment: "Label of the microphone button in the Voxa bar: a click starts listening")
        }
        public static var microphoneSend: String {
            String(localized: "Send what you said", comment: "Label of the microphone button in the Voxa bar while it listens: a click sends what was said")
        }
        public static var busyNote: String {
            String(localized: "Voxa is busy. Press Esc to stop it.", comment: "Line under the Voxa bar when a command is typed while another is running")
        }
        public static var fullControlWarning: String {
            String(localized: "Full control is on: Voxa runs what you ask without asking first.", comment: "Warning under the Voxa bar while full control is on")
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
                localized: "Opens the bar: type a command and press Return, or click the microphone, say it, and click the microphone again to send it. Esc cancels. Holding the push-to-talk key does the same from anywhere. Nothing said aloud can approve an action: a question waits for a click, the shortcut chord, or the push-to-talk key held. macOS shows its orange microphone dot while it listens.",
                comment: "Help under the Voxa bar shortcut in Settings"
            )
        }

        // MARK: Menu bar

        public static func menuOpen(_ shortcut: String?) -> String {
            shortcut.map { String(localized: "Type or Talk to Voxa… (\($0))", comment: "Menu-bar item that opens the Voxa bar. The argument is its shortcut, e.g. ⌥⇧Space") }
                ?? String(localized: "Type or Talk to Voxa…", comment: "Menu-bar item that opens the Voxa bar")
        }
    }
}

// swiftlint:enable line_length
