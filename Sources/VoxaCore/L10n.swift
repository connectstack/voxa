// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Every user-visible string in one place, so localization is a catalog exercise rather than a code hunt.
///
/// Strings use natural-language keys via `String(localized:)`, resolved against the *app* bundle. The app target owns
/// `Localizable.xcstrings`; when a key has no translation the English text below is shown, which is also what
/// unit tests see. Use interpolation (never string concatenation) so translators can reorder arguments.
public enum L10n {
    // MARK: Menu bar

    public enum Menu {
        public static func ready(_ shortcut: String) -> String {
            String(
                localized: "Ready — hold \(shortcut) to talk",
                comment: "Menu status line when idle. The argument is the shortcut"
            )
        }
        public static var readyNoShortcut: String {
            String(
                localized: "Ready — set a push-to-talk shortcut in Settings",
                comment: "Menu status line when no shortcut is configured"
            )
        }
        public static var listening: String {
            String(localized: "Listening…", comment: "Menu status line while recording")
        }
        public static var thinking: String {
            String(localized: "Thinking…", comment: "Menu status line while the model works")
        }
        public static var acting: String {
            String(localized: "Working…", comment: "Menu status line while a tool runs")
        }
        public static var confirming: String {
            String(localized: "Waiting for your answer", comment: "Menu status line while a confirmation is showing")
        }
        public static var problem: String {
            String(localized: "Something went wrong", comment: "Menu status line after an error")
        }
        public static var settings: String {
            String(localized: "Settings…", comment: "Menu item that opens the settings window")
        }
        public static var quit: String {
            String(localized: "Quit Voxa", comment: "Menu item that quits the app")
        }
        public static var accessibilityLabel: String {
            String(localized: "Voxa", comment: "VoiceOver label for the menu bar icon")
        }
    }

    // MARK: Settings

    public enum Settings {
        public static var windowTitle: String {
            String(localized: "Voxa Settings", comment: "Settings window title")
        }
        public static var general: String {
            String(localized: "General", comment: "Settings tab")
        }
        public static var pushToTalk: String {
            String(localized: "Push-to-talk shortcut", comment: "Settings label for the hotkey recorder")
        }
        public static var pushToTalkHelp: String {
            String(
                localized: "Hold the shortcut while you speak; release it to send the command.",
                comment: "Settings help text under the hotkey recorder"
            )
        }
        public static var speechEngine: String {
            String(localized: "Speech recognition", comment: "Settings label for the speech engine picker")
        }
        public static var engineAutomatic: String {
            String(localized: "Automatic (best on-device engine)", comment: "Speech engine option")
        }
        public static var engineClassic: String {
            String(localized: "Classic on-device recognizer", comment: "Speech engine option")
        }
        public static var engineHelp: String {
            String(
                localized:
                    "Audio is always transcribed on this Mac. Automatic uses the newest Apple engine when its language model is installed.",
                comment: "Settings help text under the speech engine picker"
            )
        }
        public static var language: String {
            String(localized: "Language", comment: "Settings label for the recognition language picker")
        }
        public static var downloadModel: String {
            String(localized: "Download the newer speech model automatically", comment: "Settings toggle")
        }
        public static var downloadModelHelp: String {
            String(
                localized:
                    "A one-time download managed by macOS. Until it finishes, the classic on-device recognizer is used. Your voice never leaves this Mac either way.",
                comment: "Settings help text under the model download toggle"
            )
        }
    }

    // MARK: Recovery buttons

    public enum Recovery {
        public static var openSystemSettings: String {
            String(localized: "Open System Settings", comment: "Button that opens the relevant System Settings pane")
        }
        public static var openAppSettings: String {
            String(localized: "Open Voxa Settings", comment: "Button that opens Voxa's settings window")
        }
        public static var retry: String {
            String(localized: "Try Again", comment: "Button that retries the last action")
        }
        public static var openOllama: String {
            String(localized: "Open Ollama", comment: "Button that launches the Ollama app")
        }
    }

    // MARK: Permissions

    public enum Permissions {
        public static func name(for kind: PermissionKind) -> String {
            switch kind {
            case .microphone: String(localized: "Microphone", comment: "Permission name")
            case .speechRecognition: String(localized: "Speech Recognition", comment: "Permission name")
            case .accessibility: String(localized: "Accessibility", comment: "Permission name")
            case .screenRecording: String(localized: "Screen Recording", comment: "Permission name")
            case .calendars: String(localized: "Calendars", comment: "Permission name")
            case .reminders: String(localized: "Reminders", comment: "Permission name")
            case .automation: String(localized: "Automation", comment: "Permission name")
            }
        }

        /// The title/detail pair shown when `kind` is missing. `.notDetermined` reads as a request, the rest as a fix.
        public static func text(for kind: PermissionKind, status: PermissionStatus) -> (title: String, detail: String) {
            let name = Self.name(for: kind)
            if status == .restricted {
                return (
                    String(
                        localized: "\(name) access is restricted",
                        comment: "Permission error title. The argument is the permission name"
                    ),
                    String(
                        localized: "This Mac's settings don't allow Voxa to use \(name). Ask your administrator.",
                        comment: "Permission error detail for restricted access"
                    )
                )
            }
            let title =
                status == .notDetermined
                ? String(
                    localized: "\(name) access is needed",
                    comment: "Permission error title when the user has not been asked yet"
                )
                : String(
                    localized: "\(name) access is off",
                    comment: "Permission error title when the user denied access"
                )
            return (title, why(for: kind, pane: name))
        }

        private static func why(for kind: PermissionKind, pane: String) -> String {
            switch kind {
            case .microphone:
                String(
                    localized:
                        "Voxa needs the microphone to hear your commands. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            case .speechRecognition:
                String(
                    localized:
                        "Voxa turns your voice into text with Apple's on-device speech recognition. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            case .accessibility:
                String(
                    localized:
                        "Voxa needs this to click and type in other apps for you. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            case .screenRecording:
                String(
                    localized:
                        "Voxa needs this to look at your screen when other methods fail. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            case .calendars:
                String(
                    localized:
                        "Voxa needs this to read and change your calendar for you. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            case .reminders:
                String(
                    localized:
                        "Voxa needs this to read and add your reminders for you. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            case .automation:
                String(
                    localized:
                        "Voxa needs this to control other apps for you. Turn it on in System Settings → Privacy & Security → \(pane).",
                    comment: "Permission detail"
                )
            }
        }
    }

    // MARK: Errors

    public enum Errors {
        public static var genericTitle: String {
            String(localized: "Something went wrong", comment: "Fallback error title")
        }
        public static var noInputDeviceTitle: String {
            String(localized: "No microphone found", comment: "Error title")
        }
        public static var noInputDeviceDetail: String {
            String(
                localized: "Connect a microphone or choose an input device in System Settings → Sound.",
                comment: "Error detail"
            )
        }
        public static var micStartFailedTitle: String {
            String(localized: "Couldn't start the microphone", comment: "Error title")
        }
        public static func micStartFailedDetail(_ reason: String) -> String {
            String(
                localized: "The audio system reported: \(reason)",
                comment: "Error detail. The argument is the system's description"
            )
        }
        public static var micLostTitle: String {
            String(
                localized: "The microphone stopped working",
                comment: "Error title when the input device disappears mid-recording"
            )
        }
        public static var micLostDetail: String {
            String(
                localized: "The input device changed while recording. Hold the shortcut and try again.",
                comment: "Error detail"
            )
        }
        public static func onDeviceUnavailableTitle(_ language: String) -> String {
            String(
                localized: "On-device recognition isn't available for \(language)",
                comment: "Error title. The argument is a language name"
            )
        }
        public static var onDeviceUnavailableDetail: String {
            String(
                localized:
                    "Voxa never sends your voice to a server. Add the language under System Settings → Keyboard → Dictation, or pick another language in Voxa Settings.",
                comment: "Error detail"
            )
        }
        public static var recognizerUnavailableTitle: String {
            String(localized: "Speech recognition isn't available right now", comment: "Error title")
        }
        public static var recognizerUnavailableDetail: String {
            String(
                localized: "Hold the shortcut and try again in a moment. If it keeps happening, restart Voxa.",
                comment: "Error detail"
            )
        }
        public static var recognitionFailedTitle: String {
            String(localized: "Couldn't understand the audio", comment: "Error title")
        }
        public static func recognitionFailedDetail(_ reason: String) -> String {
            String(
                localized: "The speech recognizer reported: \(reason)",
                comment: "Error detail. The argument is the system's description"
            )
        }
        public static var unsupportedLanguageTitle: String {
            String(localized: "That language isn't supported", comment: "Error title")
        }
        public static var unsupportedLanguageDetail: String {
            String(localized: "Pick a different language in Voxa Settings.", comment: "Error detail")
        }
        public static var modelDownloadFailedTitle: String {
            String(localized: "Couldn't download the speech model", comment: "Error title")
        }
        public static func modelDownloadFailedDetail(_ reason: String) -> String {
            String(
                localized: "Check your internet connection, then hold the shortcut and try again. (\(reason))",
                comment: "Error detail. The argument is the system's description"
            )
        }
    }
}

extension PermissionKind {
    public var displayName: String { L10n.Permissions.name(for: self) }
}

// swiftlint:enable line_length
