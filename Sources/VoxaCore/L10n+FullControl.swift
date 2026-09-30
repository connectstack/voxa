// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Full control: the switch in Settings, the question asked before it turns on, and the places that say it is on.
extension L10n {
    public enum FullControl {
        // MARK: Settings → Safety

        public static var section: String {
            String(localized: "Full control", comment: "Settings section title on the Safety tab")
        }
        public static var toggle: String {
            String(localized: "Run commands without asking me", comment: "Settings switch that gives Voxa full control")
        }
        public static var helpOff: String {
            String(
                localized: "Voxa asks before risky actions, such as deleting, sending, moving files, running scripts or clicking in other apps after reading something from outside. Turn this on and it just does them.",
                comment: "Help under the full control switch while it is off"
            )
        }
        public static var helpOn: String {
            String(
                localized: "Voxa is acting without asking, scripts and changes to the Mac included. It still refuses a few things whatever this says: typing into password fields, using terminals and password managers, running shell commands, and touching hidden files or your Library. Esc stops a command at any time.",
                comment: "Help under the full control switch while it is on"
            )
        }
        public static var strictnessUnused: String {
            String(
                localized: "Not used while full control is on.",
                comment: "Shown under the ask-before-acting picker while full control is on"
            )
        }

        // MARK: The question before it turns on

        public static var confirmTitle: String {
            String(localized: "Give Voxa full control?", comment: "Title of the question asked before full control turns on")
        }
        public static var confirmMessage: String {
            String(
                localized: "Voxa will carry out your commands straight away, without showing you an Allow card first. That includes deleting and moving files, changing calendar events, running AppleScripts and Shortcuts, changing settings of the Mac, and clicking and typing in other apps.\n\nVoxa also reads things from outside your commands (web pages, emails, files), and text in them can try to steer it. With full control only what Voxa refuses outright stands in the way.\n\nYou can turn this off at any time, here or from the menu bar, and Esc stops a command that is running.",
                comment: "Body of the question asked before full control turns on"
            )
        }
        public static var confirmGive: String {
            String(localized: "Give Full Control", comment: "Button that turns full control on")
        }
        public static var confirmKeepAsking: String {
            String(localized: "Keep Asking", comment: "Button that leaves full control off")
        }

        // MARK: Where it says it is on

        public static var menuOn: String {
            String(localized: "Full control is on", comment: "Menu-bar line shown while full control is on")
        }
        public static var menuTurnOff: String {
            String(localized: "Turn Off Full Control", comment: "Menu-bar item that turns full control off")
        }
        public static var toolsBanner: String {
            String(
                localized: "Full control is on, so anything marked “Asks first” runs without asking.",
                comment: "Text at the top of the Tools tab while full control is on"
            )
        }

        // MARK: In History

        public static func ranWithoutAsking(_ tool: String) -> String {
            String(
                localized: "“\(tool)” ran without asking (full control)",
                comment: "History line. The argument is a tool name"
            )
        }
    }
}

// swiftlint:enable line_length
