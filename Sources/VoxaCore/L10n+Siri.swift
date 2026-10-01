// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Talking to Voxa through Siri: Siri listens and hands Voxa the words.
extension L10n {
    public enum Siri {
        // MARK: Settings

        public static var section: String {
            String(localized: "Talk to Voxa with Siri", comment: "Settings section title for using Siri to talk to Voxa")
        }
        public static var help: String {
            String(
                localized: "Siri does the listening and hands Voxa the words, so you get Siri's own speech recognition. Say “Hey Siri, ask Voxa” (or click the Siri icon in the menu bar, or use your Siri keyboard shortcut) and, when Siri asks what Voxa should do, say it. Nothing said to Siri can approve an action: a question waits for a click, the shortcut chord, or the push-to-talk key held.",
                comment: "Help in Settings that explains how to talk to Voxa through Siri"
            )
        }
        public static var heySiriOn: String {
            String(localized: "“Hey Siri” is on: say “Hey Siri, ask Voxa” to talk without touching anything.", comment: "Settings status when Hey Siri is switched on")
        }
        public static var heySiriOff: String {
            String(localized: "“Hey Siri” is off. In System Settings, switch on “Listen for Hey Siri” to talk without touching anything, or click the Siri icon in the menu bar.", comment: "Settings status when Hey Siri is switched off")
        }
        public static var siriOff: String {
            String(localized: "Siri is turned off in System Settings, so it can't listen for Voxa.", comment: "Settings status when Siri is switched off")
        }
        public static var openSettings: String {
            String(localized: "Open Siri Settings…", comment: "Button that opens Siri's pane in System Settings")
        }

        // MARK: Menu bar

        public static var menuHeySiri: String {
            String(localized: "Talk: say “Hey Siri, ask Voxa”", comment: "Menu-bar line (not clickable) that says how to talk to Voxa when Hey Siri is on")
        }
        public static var menuTurnOnHeySiri: String {
            String(localized: "Turn On “Listen for Hey Siri” to Talk to Voxa…", comment: "Menu-bar item that opens Siri's settings, where the switch “Listen for Hey Siri” is turned on")
        }
        public static var menuTurnOnSiri: String {
            String(localized: "Turn On Siri to Talk to Voxa…", comment: "Menu-bar item that opens Siri's settings, where the switch “Siri” is turned on")
        }
    }
}

// swiftlint:enable line_length
