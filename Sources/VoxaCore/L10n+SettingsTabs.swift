// swiftlint:disable line_length
// Localized strings carry translator comments, so their lines are long by nature.
import Foundation

/// The Tools and History tabs of Settings, and the additions to General.
extension L10n {
    public enum GeneralUI {
        public static var startup: String {
            String(localized: "Start Voxa when I log in", comment: "Settings toggle")
        }
        public static var startupNeedsApproval: String {
            String(
                localized: "macOS is waiting for you to allow this in System Settings → General → Login Items.",
                comment: "Settings note under the start at login toggle when approval is pending"
            )
        }
        public static var openLoginItems: String {
            String(localized: "Open Login Items", comment: "Button that opens System Settings → Login Items")
        }
        public static func startupFailed(_ reason: String) -> String {
            String(localized: "Couldn't change this: \(reason)", comment: "Settings error under the start at login toggle. The argument is the system's reason")
        }
        public static var welcomeGuide: String {
            String(localized: "Show the welcome guide", comment: "Settings button that reopens the first-run walkthrough")
        }
    }

    public enum ToolsUI {
        public static var tab: String {
            String(localized: "Tools", comment: "Settings tab")
        }
        public static var intro: String {
            String(
                localized: "These are the things Voxa can do. Turn one off and it disappears from what the model is told about, and is refused even if asked for.",
                comment: "Settings text at the top of the Tools tab"
            )
        }
        public static var footer: String {
            String(
                localized: "Whatever is on here, Voxa always asks before anything marked “Asks first”, and asks before more once it has read something from outside your command.",
                comment: "Settings text at the bottom of the Tools tab"
            )
        }

        public enum Category: String, CaseIterable, Identifiable {
            case apps, scripts, calendar, clipboard, windows, files, other
            public var id: String { rawValue }

            public var title: String {
                switch self {
                case .apps: String(localized: "Apps and web", comment: "Tools category")
                case .scripts: String(localized: "Shortcuts and scripts", comment: "Tools category")
                case .calendar: String(localized: "Calendar and reminders", comment: "Tools category")
                case .clipboard: String(localized: "Clipboard and context", comment: "Tools category")
                case .windows: String(localized: "Other apps and the screen", comment: "Tools category")
                case .files: String(localized: "Files", comment: "Tools category")
                case .other: String(localized: "Other", comment: "Tools category")
                }
            }
        }

        public static func category(for tool: String) -> Category {
            switch tool {
            case "open_app", "open_url": .apps
            case "list_shortcuts", "run_shortcut", "run_applescript": .scripts
            case _ where tool.hasPrefix("calendar_") || tool.hasPrefix("reminders_"): .calendar
            case "clipboard_read", "clipboard_write", "get_frontmost_context": .clipboard
            case "ui_inspect", "ui_click", "ui_type", "ui_press_keys", "screenshot": .windows
            case "file_search", "reveal_in_finder", "file_move", "file_trash": .files
            default: .other
            }
        }

        public static func title(for tool: String) -> String {
            switch tool {
            case "open_app": String(localized: "Open apps", comment: "Tool name")
            case "open_url": String(localized: "Open links", comment: "Tool name")
            case "list_shortcuts": String(localized: "List Shortcuts", comment: "Tool name")
            case "run_shortcut": String(localized: "Run Shortcuts", comment: "Tool name")
            case "run_applescript": String(localized: "Run AppleScript", comment: "Tool name")
            case "calendar_list_events": String(localized: "Read your calendar", comment: "Tool name")
            case "calendar_create_event": String(localized: "Add calendar events", comment: "Tool name")
            case "calendar_update_event": String(localized: "Change calendar events", comment: "Tool name")
            case "calendar_delete_event": String(localized: "Delete calendar events", comment: "Tool name")
            case "reminders_list": String(localized: "Read your reminders", comment: "Tool name")
            case "reminders_create": String(localized: "Add reminders", comment: "Tool name")
            case "clipboard_read": String(localized: "Read the clipboard", comment: "Tool name")
            case "clipboard_write": String(localized: "Copy to the clipboard", comment: "Tool name")
            case "get_frontmost_context": String(localized: "See what's in front", comment: "Tool name")
            case "ui_inspect": String(localized: "Look at an app's window", comment: "Tool name")
            case "ui_click": String(localized: "Click in other apps", comment: "Tool name")
            case "ui_type": String(localized: "Type into other apps", comment: "Tool name")
            case "ui_press_keys": String(localized: "Press keyboard shortcuts", comment: "Tool name")
            case "screenshot": String(localized: "Look at the screen", comment: "Tool name")
            case "file_search": String(localized: "Find files", comment: "Tool name")
            case "reveal_in_finder": String(localized: "Show files in Finder", comment: "Tool name")
            case "file_move": String(localized: "Move files", comment: "Tool name")
            case "file_trash": String(localized: "Move files to the Trash", comment: "Tool name")
            default: tool.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        public static func blurb(for tool: String, fallback: String) -> String {
            switch tool {
            case "open_app": String(localized: "Opens or switches to an app you name.", comment: "Tool description")
            case "open_url": String(localized: "Opens a web page or link in your browser.", comment: "Tool description")
            case "list_shortcuts": String(localized: "Looks up the names of your Shortcuts.", comment: "Tool description")
            case "run_shortcut": String(localized: "Runs one of your Shortcuts by name.", comment: "Tool description")
            case "run_applescript": String(localized: "Runs a script that you read and approve first.", comment: "Tool description")
            case "calendar_list_events": String(localized: "Looks up your events for a day or a week.", comment: "Tool description")
            case "calendar_create_event": String(localized: "Adds an event to your calendar.", comment: "Tool description")
            case "calendar_update_event": String(localized: "Moves or renames an event, once you approve.", comment: "Tool description")
            case "calendar_delete_event": String(localized: "Deletes an event, once you approve.", comment: "Tool description")
            case "reminders_list": String(localized: "Looks up what you have to do.", comment: "Tool description")
            case "reminders_create": String(localized: "Adds a reminder.", comment: "Tool description")
            case "clipboard_read": String(localized: "Reads the text you copied. Never anything a password manager marked secret.", comment: "Tool description")
            case "clipboard_write": String(localized: "Puts text on your clipboard for you to paste.", comment: "Tool description")
            case "get_frontmost_context": String(localized: "Checks which app is in front and what is selected there.", comment: "Tool description")
            case "ui_inspect": String(localized: "Reads the names of the buttons, fields and menus of the app in front.", comment: "Tool description")
            case "ui_click": String(localized: "Presses buttons and menu items in the app in front.", comment: "Tool description")
            case "ui_type": String(localized: "Types where the cursor is. Never into a password field.", comment: "Tool description")
            case "ui_press_keys": String(localized: "Presses keys and shortcuts, such as ⌘S, in the app in front.", comment: "Tool description")
            case "screenshot": String(localized: "Takes a picture of the front window for the model to read, as a last resort.", comment: "Tool description")
            case "file_search": String(localized: "Looks up files by name in your home folder.", comment: "Tool description")
            case "reveal_in_finder": String(localized: "Shows a file in a Finder window.", comment: "Tool description")
            case "file_move": String(localized: "Moves files into a folder, once you approve. Never replaces anything.", comment: "Tool description")
            case "file_trash": String(localized: "Puts files in the Trash, once you approve. Never deletes anything.", comment: "Tool description")
            default: fallback
            }
        }

        public static func riskLabel(_ risk: RiskLevel) -> String {
            switch risk {
            case .readOnly: String(localized: "Only reads", comment: "Tool risk badge")
            case .reversible: String(localized: "Tells you", comment: "Tool risk badge")
            case .sensitive: String(localized: "Asks first", comment: "Tool risk badge")
            }
        }

        public static func needs(_ permission: String) -> String {
            String(localized: "Needs \(permission) access", comment: "Tool warning when a permission is missing. The argument is the permission's name")
        }
    }

    public enum HistoryUI {
        public static var tab: String {
            String(localized: "History", comment: "Settings tab")
        }
        public static var intro: String {
            String(
                localized: "What you asked and what Voxa did, kept only on this Mac. It records your commands, the tools used, what was decided and how each command ended, but never what a tool returned.",
                comment: "Settings text at the top of the History tab"
            )
        }
        public static var search: String {
            String(localized: "Search", comment: "History search field placeholder")
        }
        public static var empty: String {
            String(localized: "Nothing yet. Hold the shortcut and ask for something.", comment: "History tab when there are no entries")
        }
        public static var noMatches: String {
            String(localized: "Nothing matches that.", comment: "History tab when a search finds nothing")
        }
        public static var showInFinder: String {
            String(localized: "Show in Finder", comment: "History button that reveals the log file")
        }
        public static var clear: String {
            String(localized: "Clear History…", comment: "History button that deletes the log")
        }
        public static var clearTitle: String {
            String(localized: "Clear the history?", comment: "Title of the confirmation alert before deleting the log")
        }
        public static var clearMessage: String {
            String(localized: "This deletes the record of every command on this Mac. It can't be undone.", comment: "Message of the confirmation alert before deleting the log")
        }
        public static var clearConfirm: String {
            String(localized: "Clear History", comment: "Destructive button in the confirmation alert")
        }
        public static var refresh: String {
            String(localized: "Refresh", comment: "History button")
        }
        public static var unknownCommand: String {
            String(localized: "(earlier command)", comment: "History row for a run whose command text is no longer kept")
        }
        public static func summary(commands: Int, size: String) -> String {
            String(localized: "\(commands) commands · \(size)", comment: "History footer: how many commands and how much room they take")
        }
        public static func clearFailed(_ reason: String) -> String {
            String(localized: "Couldn't clear the history: \(reason)", comment: "History error")
        }

        public static func outcome(_ outcome: AuditRun.Outcome) -> String {
            switch outcome {
            case .completed: String(localized: "Done", comment: "History outcome")
            case .cancelled: String(localized: "Stopped", comment: "History outcome")
            case .failed: String(localized: "Failed", comment: "History outcome")
            case .stopped: String(localized: "Ran out of time", comment: "History outcome")
            case .refused: String(localized: "Declined by the model", comment: "History outcome")
            case .declined: String(localized: "You said no", comment: "History outcome")
            case .unfinished: String(localized: "Unfinished", comment: "History outcome")
            }
        }

        /// One line of a command's story, in plain words.
        public static func describe(_ entry: AuditEntry) -> String {
            let tool = entry.tool.map { ToolsUI.title(for: $0) } ?? ""
            switch entry.kind {
            case .command:
                return String(localized: "You said: \(entry.detail ?? "")", comment: "History line. The argument is the command")
            case .toolProposed:
                return String(localized: "Asked to use “\(tool)”", comment: "History line. The argument is a tool name")
            case .policyDecision:
                switch entry.outcome {
                case "allow": return String(localized: "“\(tool)” was allowed to run", comment: "History line")
                case "notice": return String(localized: "“\(tool)” ran, with a notice", comment: "History line")
                case "confirm": return String(localized: "Asked you about “\(tool)”", comment: "History line")
                case "deny": return String(localized: "“\(tool)” was blocked: \(entry.detail ?? "")", comment: "History line. The second argument is the reason")
                default: return String(localized: "“\(tool)” wasn't run: \(entry.detail ?? "")", comment: "History line. The second argument is the reason")
                }
            case .confirmation:
                switch entry.outcome {
                case "approved": return String(localized: "You allowed it", comment: "History line")
                case "denied": return String(localized: "You said no", comment: "History line")
                case "timeout": return String(localized: "You didn't answer, which counts as no", comment: "History line")
                default: return String(localized: "The question was withdrawn", comment: "History line")
                }
            case .toolResult:
                return entry.outcome == "error"
                    ? String(localized: "“\(tool)” hit a problem", comment: "History line")
                    : String(localized: "“\(tool)” finished", comment: "History line")
            case .permission:
                return String(localized: "“\(tool)” needed a permission that is off", comment: "History line")
            case .reply:
                return String(localized: "Voxa replied: \(entry.detail ?? "")", comment: "History line. The argument is the reply")
            case .failure:
                return String(localized: "It ended: \(entry.detail ?? "")", comment: "History line. The argument is the reason")
            }
        }
    }
}

// swiftlint:enable line_length
