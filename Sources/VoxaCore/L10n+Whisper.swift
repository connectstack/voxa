// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The Whisper speech engine: the model list in Settings, and what is said when a model isn't there.
extension L10n {
    public enum WhisperUI {
        public static var section: String {
            String(localized: "Whisper models", comment: "Settings section title")
        }
        public static var intro: String {
            String(
                localized: "Whisper runs on this Mac, so your voice never leaves it. A model is a one-time download from huggingface.co (argmaxinc/whisperkit-coreml); nothing is downloaded until you press Download.",
                comment: "Settings text above the list of Whisper models"
            )
        }
        public static var useThisOne: String {
            String(localized: "Use this one", comment: "Button that chooses a Whisper model")
        }
        public static var inUse: String {
            String(localized: "In use", comment: "Label on the Whisper model that is chosen")
        }
        public static var download: String {
            String(localized: "Download", comment: "Button that downloads a Whisper model")
        }
        public static var cancel: String {
            String(localized: "Cancel", comment: "Button that stops a Whisper model download")
        }
        public static var remove: String {
            String(localized: "Remove", comment: "Button that deletes a downloaded Whisper model")
        }
        public static var retry: String {
            String(localized: "Try again", comment: "Button that retries a Whisper model download")
        }
        public static var preparing: String {
            String(localized: "Getting it ready for this Mac (once)…", comment: "Whisper model status while it is being compiled for the chip")
        }
        public static var ready: String {
            String(localized: "Ready", comment: "Whisper model status")
        }
        public static func downloading(_ percent: Int) -> String {
            String(localized: "Downloading… \(percent)%", comment: "Whisper model status. The argument is a percentage")
        }
        public static func size(_ megabytes: Int) -> String {
            String(localized: "about \(megabytes) MB", comment: "Size of a Whisper model download")
        }
        public static func failed(_ reason: String) -> String {
            String(localized: "Didn't work: \(reason)", comment: "Whisper model status. The argument is the reason")
        }
        public static func modelTitle(name: String, englishOnly: Bool) -> String {
            englishOnly
                ? String(localized: "\(name) (English)", comment: "Whisper model name. The argument is Tiny, Base or Small")
                : String(localized: "\(name) (all languages)", comment: "Whisper model name. The argument is Tiny, Base or Small")
        }
        public static var englishOnlyNote: String {
            String(localized: "The model you chose understands English only, whatever language is set above.", comment: "Settings hint")
        }
        public static var notInstalledHint: String {
            String(localized: "Whisper is chosen, but no model is downloaded yet, so Voxa will use it only after you download one below.", comment: "Settings hint")
        }

        public static var missingTitle: String {
            String(localized: "The Whisper model isn't downloaded", comment: "Error headline")
        }
        public static func missingDetail(_ name: String) -> String {
            String(localized: "Voxa is set to use Whisper (\(name)), but that model isn't on this Mac. Download it in Settings → General, or choose another speech engine.", comment: "Error text. The argument is the model's name")
        }
        public static var failedTitle: String {
            String(localized: "Whisper couldn't transcribe that", comment: "Error headline")
        }
        public static func failedDetail(_ reason: String) -> String {
            String(localized: "Whisper reported a problem: \(reason)", comment: "Error text. The argument is the reason")
        }
    }
}

// swiftlint:enable line_length
