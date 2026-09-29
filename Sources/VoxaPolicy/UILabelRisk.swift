import Foundation

/// Reads the label of a button or menu item and says whether pressing it looks consequential.
///
/// When Voxa clicks something on the user's behalf, the model chose the target and the label is all that says what it does.
/// A button called "Delete" or "Send" is worth a question even when nothing suspicious has happened yet. This is a word
/// list, so it is English-only and will miss some things and flag some harmless ones ("Share"); a flag only ever adds a
/// question, and outside content in the conversation asks about every click anyway.
public enum UILabelRisk {
    /// Why a control with this label needs the user's say-so, in words for the confirmation card, or nil when nothing about
    /// the label looks consequential.
    public static func concern(in label: String) -> String? {
        let words = tokens(label)
        guard !words.isEmpty else { return nil }
        // "Don't Allow" and "Don't Send" are the safe choice in their dialogs. The exception is "Don't Save", which throws
        // away what was typed.
        let negated = words.contains("dont") || contains(words, sequence: ["do", "not"]) || words.first == "never"
        for category in Category.allCases where negated ? category.matchesWhenNegated(words) : category.matches(words) {
            return "\(category.explanation) (“\(shortened(label))”)."
        }
        return nil
    }

    /// The concern for any part of a path such as "File › Move to Trash".
    public static func concern(inPath parts: [String]) -> String? {
        for part in parts {
            if let found = concern(in: part) { return found }
        }
        return nil
    }

    // MARK: Categories

    private enum Category: CaseIterable {
        case destroys, sends, spends, grants, powers

        var explanation: String {
            switch self {
            case .destroys: "Its label suggests it deletes or erases something"
            case .sends: "Its label suggests it sends or publishes something"
            case .spends: "Its label suggests it spends money or subscribes"
            case .grants: "Its label suggests it grants access or accepts terms"
            case .powers: "Its label suggests it quits, restarts or logs out"
            }
        }

        var words: Set<String> {
            switch self {
            case .destroys: ["delete", "remove", "erase", "wipe", "destroy", "uninstall", "discard", "reset", "purge"]
            case .sends: ["send", "post", "publish", "submit", "tweet", "invite", "upload"]
            case .spends: ["buy", "purchase", "pay", "checkout", "subscribe", "donate", "transfer", "install"]
            case .grants: ["allow", "grant", "authorize", "authorise", "approve", "accept", "agree", "trust", "unlock"]
            case .powers: ["quit", "restart", "reboot", "logout", "shutdown"]
            }
        }

        var phrases: [[String]] {
            switch self {
            case .destroys:
                [["empty", "trash"], ["empty", "bin"], ["move", "to", "trash"], ["move", "to", "bin"], ["clear", "all"],
                 ["clear", "history"], ["dont", "save"], ["do", "not", "save"]]
            case .sends: []
            case .spends: [["place", "order"], ["confirm", "order"], ["order", "now"], ["check", "out"], ["buy", "now"], ["add", "payment"]]
            case .grants: [["i", "agree"]]
            case .powers: [["shut", "down"], ["log", "out"], ["sign", "out"], ["force", "quit"]]
            }
        }

        func matches(_ tokens: [String]) -> Bool {
            if tokens.contains(where: { words.contains($0) }) { return true }
            return phrases.contains { contains(tokens, sequence: $0) }
        }

        /// What still counts when the label is a refusal ("Don't …"): only the phrase that means losing work.
        func matchesWhenNegated(_ tokens: [String]) -> Bool {
            self == .destroys && [["dont", "save"], ["do", "not", "save"]].contains { contains(tokens, sequence: $0) }
        }
    }

    // MARK: Helpers

    /// Lowercase words, with apostrophes dropped so "Don't Save" becomes `dont`, `save`.
    static func tokens(_ label: String) -> [String] {
        let folded = label.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
        var words: [String] = []
        var current = ""
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func contains(_ tokens: [String], sequence: [String]) -> Bool {
        guard !sequence.isEmpty, tokens.count >= sequence.count else { return false }
        for start in 0...(tokens.count - sequence.count) where Array(tokens[start..<(start + sequence.count)]) == sequence {
            return true
        }
        return false
    }

    private static func shortened(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
    }
}
