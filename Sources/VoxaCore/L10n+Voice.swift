// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Speaking replies aloud: the Settings section, and the few sentences Voxa says that aren't the model's.
extension L10n {
    public enum VoiceSettings {
        public static var section: String {
            String(localized: "Voice", comment: "Settings section title for spoken replies")
        }
        public static var speakReplies: String {
            String(localized: "Speak replies aloud", comment: "Settings toggle")
        }
        public static var speakRepliesHelp: String {
            String(
                localized: "Replies are also shown on screen. Holding the shortcut, or pressing Esc, stops the speech at once.",
                comment: "Settings help text under the speak replies toggle"
            )
        }
        public static var voice: String {
            String(localized: "Voice", comment: "Settings label for the voice picker")
        }
        public static var bestAvailable: String {
            String(localized: "Best available for my language", comment: "Voice picker option that chooses the most natural installed voice")
        }
        public static var speed: String {
            String(localized: "Speed", comment: "Settings label for the speaking speed slider")
        }
        public static var slower: String {
            String(localized: "Slower", comment: "Label at the slow end of the speed slider")
        }
        public static var faster: String {
            String(localized: "Faster", comment: "Label at the fast end of the speed slider")
        }
        public static var test: String {
            String(localized: "Test voice", comment: "Button that speaks a sample sentence")
        }
        public static var improveHint: String {
            String(
                localized: "For a more natural voice, download one in System Settings → Accessibility → Spoken Content.",
                comment: "Settings hint under the voice picker"
            )
        }
    }

    public enum VoiceSpoken {
        /// What Voxa says when it wants to hear the test voice.
        public static var sample: String {
            String(localized: "Hi, I'm Voxa. This is how I sound.", comment: "Sentence spoken by the Test voice button")
        }

        /// A confirmation, said aloud so it can be answered without looking.
        public static func question(_ title: String) -> String {
            String(
                localized: "\(title)? Hold the shortcut and say yes or no.",
                comment: "Spoken confirmation question. The argument is what Voxa wants to do, for example 'Run an AppleScript'"
            )
        }
    }
}

// swiftlint:enable line_length
