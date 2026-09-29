import Foundation

/// Strings for the HUD.
extension L10n {
    // MARK: HUD

    public enum HUD {
        public static var preparing: String {
            String(localized: "Getting ready…", comment: "HUD status while the microphone is starting")
        }
        public static var listening: String {
            String(localized: "Listening…", comment: "HUD status while the microphone is open")
        }
        public static var transcribing: String {
            String(
                localized: "Transcribing…",
                comment: "HUD status after the key is released, while speech-to-text finishes"
            )
        }
        public static var heard: String {
            String(localized: "Heard", comment: "HUD title above the recognized command")
        }
        public static var placeholder: String {
            String(localized: "Say a command…", comment: "HUD placeholder before any words are recognized")
        }
        public static func releaseToSend(_ shortcut: String) -> String {
            String(
                localized: "Release \(shortcut) to send",
                comment: "HUD hint while push-to-talk is held. The argument is the shortcut, e.g. ⌥Space"
            )
        }
        public static var escapeKeyLabel: String {
            String(localized: "esc", comment: "Label on the escape key cap in the HUD")
        }
        public static var cancelHint: String {
            String(localized: "to cancel", comment: "HUD hint shown after the escape key cap")
        }
        public static var didntCatch: String {
            String(localized: "I didn't catch that", comment: "HUD title when no speech was recognized")
        }
        public static func didntCatchDetail(_ shortcut: String) -> String {
            String(
                localized: "Hold \(shortcut) and speak, then release.",
                comment: "HUD detail when no speech was recognized. The argument is the shortcut"
            )
        }
        public static var holdToTalk: String {
            String(
                localized: "Hold the shortcut while you speak",
                comment: "HUD title shown when the shortcut was tapped instead of held"
            )
        }
        public static func holdToTalkDetail(_ shortcut: String) -> String {
            String(
                localized: "Hold \(shortcut), speak, then release.",
                comment: "HUD detail under 'Hold the shortcut while you speak'. The argument is the shortcut"
            )
        }
        public static var allSet: String {
            String(
                localized: "You're all set",
                comment: "HUD title after the user granted a permission while the shortcut was already released"
            )
        }
        public static func allSetDetail(_ shortcut: String) -> String {
            String(
                localized: "Hold \(shortcut) and speak your command.",
                comment: "HUD detail under 'You're all set'. The argument is the shortcut"
            )
        }
        public static var notConnectedYet: String {
            String(
                localized: "Voice capture only. Command execution isn't connected yet.",
                comment: "Development-milestone footnote under the recognized command"
            )
        }
        public static var downloadingModel: String {
            String(
                localized: "Downloading the on-device speech model…",
                comment: "HUD status while the speech model downloads"
            )
        }
        public static func accessibilityStatus(_ status: String, transcript: String) -> String {
            String(
                localized: "Voxa, \(status). \(transcript)",
                comment: "VoiceOver label for the HUD: status followed by the transcript"
            )
        }
        public static var meterLabel: String {
            String(localized: "Input level", comment: "VoiceOver label for the microphone level meter")
        }
        public static var thinking: String {
            String(localized: "Thinking…", comment: "HUD status while the model works on the command")
        }
        public static var replyTitle: String {
            String(localized: "Voxa", comment: "HUD title above the assistant's reply")
        }
        public static func followUpHint(_ shortcut: String) -> String {
            String(
                localized: "Hold \(shortcut) to follow up",
                comment: "HUD hint under a reply. The argument is the shortcut"
            )
        }
        public static var allow: String {
            String(localized: "Allow", comment: "Confirmation button that approves the action")
        }
        public static var dontAllow: String {
            String(localized: "Don't Allow", comment: "Confirmation button that declines the action")
        }
        public static var allowKeyLabel: String {
            String(
                localized: "⌘↩",
                comment: "Label on the key cap next to Allow in a confirmation: Command plus the Return key's symbol"
            )
        }
        public static func voiceAnswerHint(_ shortcut: String) -> String {
            String(
                localized: "Or hold \(shortcut) and say “yes” or “no”",
                comment: "Confirmation hint about answering by voice. The argument is the shortcut"
            )
        }
        public static var voiceAnswerHintNoShortcut: String {
            String(
                localized: "Or answer with the buttons",
                comment: "Confirmation hint when no push-to-talk shortcut is set"
            )
        }
        public static var answerListening: String {
            String(
                localized: "Listening… say yes or no",
                comment: "Confirmation status while the microphone is open for an answer"
            )
        }
        public static var answerUnclear: String {
            String(
                localized: "I didn't catch a clear yes or no. Try again, or use the buttons.",
                comment: "Confirmation status when the spoken answer wasn't a clear yes or no"
            )
        }
        public static var confirmStopHint: String {
            String(
                localized: "to stop",
                comment: "Hint after the escape key cap in a confirmation: pressing it stops the whole command"
            )
        }
        public static func confirmAnnouncement(_ title: String, _ summary: String) -> String {
            String(
                localized:
                    "Voxa is asking permission. \(title). \(summary). Press command-return to allow, or escape to stop.",
                comment:
                    "VoiceOver announcement when a confirmation appears. The arguments are the action's title and summary"
            )
        }
        public static var reasonsLabel: String {
            String(localized: "Why Voxa is asking", comment: "VoiceOver label for the reasons list in a confirmation")
        }
    }
}
