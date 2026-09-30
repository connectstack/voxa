// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The check that a command is really finished before Voxa says so: its switch in Settings, and how History tells it.
extension L10n {
    public enum CompletionCheck {
        public static var toggle: String {
            String(localized: "Check that a command is finished", comment: "Settings switch on the Safety tab")
        }
        public static var help: String {
            String(
                localized: "Before Voxa says a command is done, it asks the model once more, in a short separate request, whether everything you asked for was really done: opening a page is not playing it. If not, it carries on. This adds one short request after commands that open or click things.",
                comment: "Help under the completion check switch"
            )
        }
        public static var checkedDone: String {
            String(localized: "Checked that it was finished: yes", comment: "History line")
        }
        public static func checkedNotYet(_ missing: String) -> String {
            String(localized: "Checked that it was finished: not yet (\(missing))", comment: "History line. The argument is what was still left to do")
        }
        public static var checkUnavailable: String {
            String(localized: "Couldn't check whether it was finished", comment: "History line")
        }
    }
}

// swiftlint:enable line_length
