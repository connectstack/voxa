// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The Permissions tab of Settings and the walkthrough's permission rows.
extension L10n {
    public enum PermissionsUI {
        public static var tab: String {
            String(localized: "Permissions", comment: "Settings tab")
        }

        public static var intro: String {
            String(
                localized: "Voxa asks for each permission only when something needs it. You can also allow them here ahead of time. Nothing here is used unless you hold the shortcut and ask.",
                comment: "Settings text at the top of the Permissions tab"
            )
        }

        /// What Voxa uses the permission for, in one line.
        public static func purpose(for kind: PermissionKind) -> String {
            switch kind {
            case .microphone:
                String(localized: "Hears your commands, only while you hold the shortcut.", comment: "What the Microphone permission is for")
            case .speechRecognition:
                String(localized: "Turns your voice into text: on this Mac, unless you choose Apple online recognition in Settings.", comment: "What the Speech Recognition permission is for")
            case .accessibility:
                String(localized: "Lets Voxa see what is in front, and press buttons and type in other apps when you ask.", comment: "What the Accessibility permission is for")
            case .screenRecording:
                String(localized: "Lets Voxa look at the front window when it can't read an app any other way.", comment: "What the Screen Recording permission is for")
            case .calendars:
                String(localized: "Reads, adds and changes your calendar events when you ask.", comment: "What the Calendars permission is for")
            case .reminders:
                String(localized: "Reads and adds your reminders when you ask.", comment: "What the Reminders permission is for")
            case .automation:
                String(localized: "Lets a script or Shortcut you approve control another app. macOS asks once for each app.", comment: "What the Automation permission is for")
            }
        }

        public static func statusLabel(_ status: PermissionStatus) -> String {
            switch status {
            case .granted: String(localized: "Allowed", comment: "Permission status")
            case .notDetermined: String(localized: "Not asked yet", comment: "Permission status")
            case .denied: String(localized: "Off", comment: "Permission status")
            case .restricted: String(localized: "Restricted", comment: "Permission status")
            }
        }

        public static var allow: String {
            String(localized: "Allow…", comment: "Button that asks macOS for a permission")
        }

        public static var openSystemSettings: String {
            String(localized: "Open System Settings", comment: "Button that opens the System Settings pane for a permission")
        }

        public static var automationNote: String {
            String(
                localized: "Automation can't be allowed ahead of time. macOS asks the first time a script you approve controls an app, and you can change it later in System Settings → Privacy & Security → Automation.",
                comment: "Explanation under the Automation row"
            )
        }

        /// How to switch on a permission that is turned on in System Settings, including what to do when it is already listed there.
        public static func switchOnNote(_ name: String) -> String {
            String(
                localized: "Press Allow…, then switch Voxa on in System Settings → Privacy & Security → \(name). If Voxa is already on there but this still says Not asked yet, select it, press − to remove it, and press Allow… again.",
                comment: "Explanation under Accessibility or Screen Recording. The argument is the permission's name"
            )
        }

        public static var restrictedNote: String {
            String(
                localized: "This Mac's settings don't let Voxa use it. Ask whoever manages this Mac.",
                comment: "Explanation for a permission that is restricted by policy"
            )
        }

        public static var deniedNote: String {
            String(
                localized: "You turned this off. Switch it back on in System Settings, then come back here.",
                comment: "Explanation for a permission the user denied"
            )
        }
    }
}

// swiftlint:enable line_length
