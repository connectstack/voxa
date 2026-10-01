// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Strings for the model connection and its settings.
extension L10n {
    // MARK: Language model

    public enum LLM {
        public static var missingKeyTitle: String {
            String(localized: "Add your Anthropic API key", comment: "Error title when no API key is stored")
        }
        public static var missingKeyDetail: String {
            String(
                localized:
                    "Voxa needs an API key to think. Add one in Settings → Model. It is stored only in your Keychain.",
                comment: "Error detail"
            )
        }
        public static var authTitle: String {
            String(localized: "Your API key was rejected", comment: "Error title for HTTP 401")
        }
        public static var authDetail: String {
            String(
                localized: "Check the key in Settings → Model, or create a new one in the Anthropic Console.",
                comment: "Error detail"
            )
        }
        public static var permissionTitle: String {
            String(localized: "This key isn't allowed to do that", comment: "Error title for HTTP 403")
        }
        public static var modelTitle: String {
            String(localized: "That model isn't available", comment: "Error title for HTTP 404")
        }
        public static var modelDetail: String {
            String(
                localized: "The model name is wrong or your account can't use it. Pick another in Settings → Model.",
                comment: "Error detail"
            )
        }
        public static var badRequestTitle: String {
            String(localized: "Anthropic rejected the request", comment: "Error title for HTTP 400")
        }
        public static var tooLargeTitle: String {
            String(localized: "The conversation got too long", comment: "Error title for HTTP 413")
        }
        public static var tooLargeDetail: String {
            String(localized: "Try the command again; Voxa will start a fresh conversation.", comment: "Error detail")
        }
        public static var rateLimitTitle: String {
            String(localized: "Anthropic is rate-limiting this key", comment: "Error title for HTTP 429")
        }
        public static var rateLimitDetail: String {
            String(localized: "Wait a few seconds, then hold the shortcut and try again.", comment: "Error detail")
        }
        public static var busyTitle: String {
            String(localized: "Anthropic is busy right now", comment: "Error title for overloaded or server errors")
        }
        public static var busyDetail: String {
            String(localized: "Try again in a moment.", comment: "Error detail")
        }
        public static var offlineTitle: String {
            String(localized: "Can't reach Anthropic", comment: "Error title for network failures")
        }
        public static func offlineDetail(_ reason: String) -> String {
            String(
                localized: "Check your internet connection. (\(reason))",
                comment: "Error detail. The argument is the system's description"
            )
        }
        public static var timeoutTitle: String {
            String(localized: "Anthropic took too long to answer", comment: "Error title")
        }
        public static var timeoutDetail: String {
            String(localized: "Try again in a moment.", comment: "Error detail")
        }
        public static var keyEmptyTitle: String {
            String(localized: "The key is empty", comment: "Error title when saving a blank API key")
        }
        public static var keyEmptyDetail: String {
            String(localized: "Paste your Anthropic API key, then save.", comment: "Error detail")
        }
        public static var keyMalformedTitle: String {
            String(
                localized: "That doesn't look like an API key",
                comment: "Error title when the pasted key contains spaces"
            )
        }
        public static var keyMalformedDetail: String {
            String(
                localized: "A key is a single string with no spaces. Copy it again from the Anthropic Console.",
                comment: "Error detail"
            )
        }
        public static var keychainTitle: String {
            String(localized: "Couldn't use the Keychain", comment: "Error title")
        }
        public static func keychainDetail(_ status: Int) -> String {
            String(
                localized: "macOS returned Keychain error \(status). If a prompt is waiting, allow Voxa to access it.",
                comment: "Error detail. The argument is a numeric status code"
            )
        }
        public static var cutOffTitle: String {
            String(
                localized: "Anthropic's reply was cut off",
                comment: "Error title for malformed or truncated streams"
            )
        }
        public static var cutOffDetail: String {
            String(localized: "Hold the shortcut and try again.", comment: "Error detail")
        }
    }

    // MARK: Settings: model and safety

    public enum SettingsModel {
        public static var tab: String {
            String(localized: "Model", comment: "Settings tab")
        }
        public static var safetyTab: String {
            String(localized: "Safety", comment: "Settings tab")
        }
        public static var apiKey: String {
            String(localized: "Anthropic API key", comment: "Settings section title")
        }
        public static var keyPlaceholder: String {
            String(localized: "Paste your key (sk-ant-…)", comment: "Placeholder in the API key field")
        }
        public static var keySaved: String {
            String(localized: "A key is saved in your Keychain.", comment: "Settings status when an API key exists")
        }
        public static var noKey: String {
            String(
                localized: "No key yet. Voxa needs one to work out what to do.",
                comment: "Settings status when no API key exists"
            )
        }
        public static var save: String {
            String(localized: "Save", comment: "Button that saves the API key")
        }
        public static var remove: String {
            String(localized: "Remove", comment: "Button that deletes the API key")
        }
        public static var replace: String {
            String(localized: "Replace…", comment: "Button that lets the user type a different API key")
        }
        public static var cancel: String {
            String(localized: "Cancel", comment: "Button that abandons replacing the API key")
        }
        public static var testConnection: String {
            String(localized: "Test connection", comment: "Button that checks the API key works")
        }
        public static var testing: String {
            String(localized: "Testing…", comment: "Status while the connection test runs")
        }
        public static var connected: String {
            String(localized: "Connected.", comment: "Status after a successful connection test")
        }
        public static var privacy: String {
            String(
                localized:
                    "Your voice is turned into text on this Mac and never leaves it, unless you choose Apple online recognition in Settings. The text of your command, and anything a tool reads for you, is sent to Anthropic to decide what to do. The key is kept in the macOS Keychain.",
                comment: "Settings privacy note under the API key"
            )
        }
        public static var modelName: String {
            String(localized: "Model", comment: "Settings label for the model identifier")
        }
        public static var modelHelp: String {
            String(
                localized: "The default works well. Any Anthropic model ID can be used.",
                comment: "Help under the model field"
            )
        }
        public static var resetModel: String {
            String(localized: "Use default", comment: "Button that restores the default model")
        }
        public static var effort: String {
            String(localized: "Thinking", comment: "Settings label for reasoning effort")
        }
        public static var effortLow: String {
            String(localized: "Quick", comment: "Reasoning effort option")
        }
        public static var effortMedium: String {
            String(localized: "Balanced", comment: "Reasoning effort option")
        }
        public static var effortHigh: String {
            String(localized: "Thorough", comment: "Reasoning effort option")
        }
        public static var effortHelp: String {
            String(
                localized: "Quick answers suit voice best; thorough is slower.",
                comment: "Help under the thinking picker"
            )
        }
        public static var strictness: String {
            String(localized: "Ask before acting", comment: "Settings label for the confirmation strictness picker")
        }
        public static var strictnessStandard: String {
            String(localized: "Only for risky actions", comment: "Strictness option")
        }
        public static var strictnessStrict: String {
            String(localized: "For every change", comment: "Strictness option")
        }
        public static var strictnessParanoid: String {
            String(localized: "For everything", comment: "Strictness option")
        }
        public static var strictnessHelp: String {
            String(
                localized:
                    "Risky actions (deleting, sending, running scripts) always ask, and so does anything that follows content Voxa read from outside your command. Stricter settings ask more often.",
                comment: "Help under the strictness picker"
            )
        }
        public static func followUp(_ seconds: Int) -> String {
            String(
                localized: "Follow-up window: \(seconds) seconds",
                comment: "Settings label. The argument is a number of seconds"
            )
        }
        public static var followUpHelp: String {
            String(
                localized:
                    "How long after a command a follow-up like “make it three hours” still refers to it. Set to 0 to always start fresh.",
                comment: "Help under the follow-up stepper"
            )
        }
        public static func maxSteps(_ steps: Int) -> String {
            String(
                localized: "Steps per command: \(steps)",
                comment: "Settings label. The argument is a number of steps"
            )
        }
    }
}

// swiftlint:enable line_length
