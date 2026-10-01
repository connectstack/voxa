// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The first-run walkthrough.
extension L10n {
    public enum Onboarding {
        public static var windowTitle: String {
            String(localized: "Welcome to Voxa", comment: "Title of the first-run window")
        }

        // MARK: Welcome
        public static var welcomeTitle: String {
            String(localized: "Talk to your Mac", comment: "Welcome step headline")
        }
        public static func welcomeHold(_ shortcut: String) -> String {
            String(localized: "Hold \(shortcut), say what you want, and let go. Voxa does it and tells you what happened.", comment: "Welcome step. The argument is the push-to-talk shortcut")
        }
        public static var welcomeCan: String {
            String(localized: "It can open apps and links, work with your calendar, reminders, clipboard and files, use other apps for you, and run your Shortcuts.", comment: "Welcome step")
        }
        public static var welcomeAsks: String {
            String(localized: "It asks first before anything that can't be undone, and you can say yes or no out loud.", comment: "Welcome step")
        }
        public static var welcomePrivate: String {
            String(localized: "Your voice is turned into text on this Mac and never leaves it, unless you choose Apple online recognition in Settings. The model you choose gets the words of your command, and whatever Voxa has to read to carry it out, such as a calendar entry or what is in a window.", comment: "Welcome step")
        }

        // MARK: Permissions
        public static var permissionsTitle: String {
            String(localized: "Let Voxa listen", comment: "Permissions step headline")
        }
        public static var permissionsNeeded: String {
            String(localized: "Needed to hear you", comment: "Permissions step section title")
        }
        public static var permissionsOptional: String {
            String(localized: "Only if you want these", comment: "Permissions step section title")
        }
        public static var permissionsOptionalNote: String {
            String(localized: "Skip any of these. Voxa asks at the moment a command needs one, and you can change them later in Settings → Permissions.", comment: "Permissions step note")
        }

        // MARK: Model
        public static var modelTitle: String {
            String(localized: "Choose the model that thinks", comment: "Model step headline")
        }
        public static var modelNote: String {
            String(localized: "Voxa needs a model to work out what to do: Claude or OpenAI with your own key, or one that runs on this Mac through Ollama.", comment: "Model step")
        }

        // MARK: Ready
        public static var readyTitle: String {
            String(localized: "You're ready", comment: "Final step headline")
        }
        public static func readyTry(_ shortcut: String) -> String {
            String(localized: "Hold \(shortcut) and try:", comment: "Final step. The argument is the shortcut")
        }
        public static var readyExamples: [String] {
            [
                String(localized: "“Open Notes”", comment: "Example command"),
                String(localized: "“What's on my calendar today?”", comment: "Example command"),
                String(localized: "“Remind me to call the bank tomorrow at ten”", comment: "Example command"),
                String(localized: "“Copy the address I have selected”", comment: "Example command"),
            ]
        }
        public static var readyLater: String {
            String(localized: "Voxa lives in the menu bar. Settings, the tools it can use and the history of what it did are all there.", comment: "Final step")
        }
        public static var missingMicrophone: String {
            String(localized: "The microphone isn't on yet, so Voxa can't hear you. Go back to allow it.", comment: "Final step warning")
        }
        public static var missingModel: String {
            String(localized: "No model is set up yet, so commands will ask you to add one.", comment: "Final step warning")
        }

        // MARK: Buttons
        public static var back: String {
            String(localized: "Back", comment: "Walkthrough button")
        }
        public static var next: String {
            String(localized: "Continue", comment: "Walkthrough button")
        }
        public static var skip: String {
            String(localized: "Skip for now", comment: "Walkthrough button")
        }
        public static var done: String {
            String(localized: "Start using Voxa", comment: "Walkthrough button on the last step")
        }
        public static func stepLabel(_ current: Int, of total: Int) -> String {
            String(localized: "Step \(current) of \(total)", comment: "VoiceOver label for the walkthrough's progress")
        }
    }
}

// swiftlint:enable line_length
