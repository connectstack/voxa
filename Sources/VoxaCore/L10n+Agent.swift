// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// Strings for what the agent says and why it asks.
extension L10n {
    // MARK: Policy

    /// Why Voxa is asking, and why it refused. Shown in the confirmation and in the HUD, so plain words matter.
    public enum Policy {
        public static func toolDisabled(_ tool: String) -> String {
            String(
                localized: "The “\(tool)” action is turned off in Voxa Settings.",
                comment:
                    "Shown when the model tries a tool the user disabled. The argument is the tool's technical name"
            )
        }
        public static func taint(_ sources: [String]) -> String {
            let list = sources.joined(separator: ", ")
            return String(
                localized:
                    "Voxa read content from outside your command (\(list)), so it is double-checking before it acts.",
                comment:
                    "Reason shown in a confirmation when untrusted content was read earlier in the conversation. The argument lists the sources, e.g. the clipboard"
            )
        }
        public static var strictAsks: String {
            String(
                localized: "You asked Voxa to confirm every action that changes something.",
                comment: "Reason shown in a confirmation under the Strict setting"
            )
        }
        public static var paranoidAsks: String {
            String(
                localized: "You asked Voxa to confirm every action, even looking things up.",
                comment: "Reason shown in a confirmation under the Paranoid setting"
            )
        }
        public static var sensitiveAsks: String {
            String(
                localized: "This kind of action always needs your OK.",
                comment: "Reason shown when an action is sensitive"
            )
        }
        public static var mailtoDraft: String {
            String(localized: "Opens a draft in your mail app. Nothing is sent.", comment: "Reason for a mailto: link")
        }
        public static var startsCommunication: String {
            String(localized: "Starts a call or a message.", comment: "Reason for tel:, facetime: and sms: links")
        }
        public static var notEncrypted: String {
            String(
                localized: "The address isn't encrypted (http instead of https).",
                comment: "Reason for an http:// link"
            )
        }
        public static var lookalikeName: String {
            String(
                localized: "The site name uses international characters that can imitate another site.",
                comment: "Reason for an internationalized host name"
            )
        }
        public static var localNetwork: String {
            String(
                localized: "The address points at a device on your own network, not a public website.",
                comment: "Reason for a localhost/private address"
            )
        }
        public static var rawIPAddress: String {
            String(
                localized: "The address is a bare number, not a website name.",
                comment: "Reason for an IP-address link"
            )
        }
        public static func carriesLotsOfData(_ characters: Int) -> String {
            String(
                localized: "The address is very long (\(characters) characters) and can carry data out of your Mac.",
                comment: "Reason for an unusually long link. The argument is its length"
            )
        }
    }

    // MARK: Agent replies

    /// What Voxa itself says when the run ends without the model having the last word.
    public enum Agent {
        public static var refused: String {
            String(localized: "I can't help with that.", comment: "Reply when the model declined the request")
        }
        public static func limitReached(_ steps: Int) -> String {
            String(
                localized: "I used all \(steps) steps and I'm not finished. Say “continue” and I'll carry on from here.",
                comment: "Reply when the step limit is reached. The argument is the limit"
            )
        }
        public static var timedOut: String {
            String(
                localized: "That took too long, so I stopped. Part of it may have been done.",
                comment: "Reply when the total time limit is reached"
            )
        }
        public static var declinedStop: String {
            String(localized: "Okay, I've stopped.", comment: "Reply after the user declined actions more than once")
        }
        public static var done: String {
            String(localized: "Done.", comment: "Reply when the model finished without saying anything")
        }
        public static var noReply: String {
            String(
                localized: "I'm not sure how to help with that.",
                comment: "Reply when the model produced no text and did nothing"
            )
        }
        public static var busy: String {
            String(
                localized: "I'm still working on the last command.",
                comment: "Shown when a command starts while another is running"
            )
        }
        public static var noTools: String {
            String(
                localized: "Every action is turned off in Voxa Settings, so I can't do anything yet.",
                comment: "Shown when all tools are disabled"
            )
        }
    }
}

// swiftlint:enable line_length
