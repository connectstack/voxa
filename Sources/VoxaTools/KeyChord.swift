import Foundation

/// One key press with modifiers, such as ⌘S: what `ui_press_keys` is given as text like `cmd+s`.
public struct KeyChord: Sendable, Equatable, Hashable {
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    /// Keys with no character of their own.
    public enum NamedKey: String, Sendable, Hashable, CaseIterable {
        case `return`, tab, space, delete, forwardDelete, escape
        case left, right, up, down, home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

        /// The key's fixed code on a Mac keyboard, which doesn't depend on the layout.
        var virtualKey: UInt16 {
            switch self {
            case .return: 36
            case .tab: 48
            case .space: 49
            case .delete: 51
            case .escape: 53
            case .forwardDelete: 117
            case .left: 123
            case .right: 124
            case .down: 125
            case .up: 126
            case .home: 115
            case .end: 119
            case .pageUp: 116
            case .pageDown: 121
            case .f1: 122
            case .f2: 120
            case .f3: 99
            case .f4: 118
            case .f5: 96
            case .f6: 97
            case .f7: 98
            case .f8: 100
            case .f9: 101
            case .f10: 109
            case .f11: 103
            case .f12: 111
            case .f13: 105
            case .f14: 107
            case .f15: 113
            case .f16: 106
            case .f17: 64
            case .f18: 79
            case .f19: 80
            case .f20: 90
            }
        }

        var display: String {
            switch self {
            case .return: "Return"
            case .tab: "Tab"
            case .space: "Space"
            case .delete: "Delete"
            case .forwardDelete: "Forward Delete"
            case .escape: "Esc"
            case .left: "←"
            case .right: "→"
            case .up: "↑"
            case .down: "↓"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "Page Up"
            case .pageDown: "Page Down"
            default: rawValue.uppercased()
            }
        }
    }

    public enum Key: Sendable, Hashable {
        /// A letter, digit or symbol, found on whatever keyboard layout is in use.
        case character(Character)
        case named(NamedKey)
    }

    public struct ParseError: Error, Equatable, Sendable {
        public var message: String
    }

    public var key: Key
    public var modifiers: Modifiers

    public init(key: Key, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    // MARK: Text

    /// Reads `cmd+shift+4`, `return`, `ctrl+alt+left`, `f5`, `cmd+plus`. Case doesn't matter; the last part is the key.
    public static func parse(_ text: String) throws -> KeyChord {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError(message: "A key can't be empty.") }

        // `+` and `cmd++` mean the plus key itself; otherwise the last part is the key and the rest are modifiers.
        let modifierText: String
        let keyName: String
        if trimmed == "+" {
            (modifierText, keyName) = ("", "+")
        } else if trimmed.hasSuffix("++") {
            (modifierText, keyName) = (String(trimmed.dropLast(2)), "+")
        } else {
            var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            keyName = parts.removeLast()
            modifierText = parts.joined(separator: "+")
        }
        guard !keyName.isEmpty else { throw ParseError(message: "'\(trimmed)' has no key in it.") }

        var modifiers: Modifiers = []
        for name in modifierText.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let modifier = modifier(named: name) else {
                throw ParseError(message: "'\(name)' in '\(trimmed)' isn't a modifier. Use cmd, shift, option (alt), ctrl or fn.")
            }
            modifiers.insert(modifier)
        }
        return KeyChord(key: try key(named: keyName, in: trimmed), modifiers: modifiers)
    }

    private static func modifier(named name: String) -> Modifiers? {
        switch name.lowercased() {
        case "cmd", "command", "⌘", "meta", "super": .command
        case "shift", "⇧": .shift
        case "opt", "option", "alt", "⌥": .option
        case "ctrl", "control", "⌃": .control
        case "fn", "function": .function
        default: nil
        }
    }

    private static let aliases: [String: NamedKey] = [
        "return": .return, "enter": .return, "tab": .tab, "space": .space, "spacebar": .space, "delete": .delete,
        "backspace": .delete, "del": .delete, "forwarddelete": .forwardDelete, "forward_delete": .forwardDelete,
        "escape": .escape, "esc": .escape, "left": .left, "leftarrow": .left, "right": .right, "rightarrow": .right,
        "up": .up, "uparrow": .up, "down": .down, "downarrow": .down, "home": .home, "end": .end, "pageup": .pageUp,
        "page_up": .pageUp, "pgup": .pageUp, "pagedown": .pageDown, "page_down": .pageDown, "pgdn": .pageDown,
    ]

    private static let symbolNames: [String: Character] = [
        "plus": "+", "minus": "-", "equals": "=", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "semicolon": ";", "quote": "'", "backtick": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    private static func key(named name: String, in whole: String) throws -> Key {
        let lower = name.lowercased()
        if let named = aliases[lower] ?? NamedKey(rawValue: lower) { return .named(named) }
        if let symbol = symbolNames[lower] { return .character(symbol) }
        if name.count == 1, let character = name.first, !character.isWhitespace, !character.isNewline {
            return .character(Character(character.lowercased()))
        }
        throw ParseError(
            message: "'\(name)' in '\(whole)' isn't a key Voxa knows. Use one letter, digit or symbol, "
                + "or a name such as return, tab, space, escape, delete, left, right, up, down, home, end, pageup, pagedown or f1 to f20."
        )
    }

    /// The chord the way a menu shows it: ⇧⌘4, Return, ⌥←.
    public var displayString: String {
        var text = ""
        if modifiers.contains(.function) { text += "fn " }
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .named(let named): text += named.display
        }
        return text
    }

    // MARK: What it does

    /// Whether the key is Return, which presses the default button of a dialog and sends what is typed in most chat apps.
    public var isReturn: Bool {
        if case .named(.return) = key { return true }
        return false
    }

    /// A plain character: what typing produces, so it is what a password field would receive.
    public var isTypedCharacter: Bool {
        guard case .character = key else { return false }
        return modifiers.isDisjoint(with: [.command, .control, .function])
    }

    /// What this shortcut does, when that is the loss of something or the end of the session; nil for the rest. These are
    /// system-wide meanings, so they hold in whichever app is in front.
    public var consequence: String? {
        let flags = modifiers
        switch key {
        case .character("q"):
            if flags == [.command] { return "Quits the app, closing its windows without asking to save." }
            if flags == [.command, .shift] { return "Logs out of the Mac." }
            if flags == [.command, .shift, .option] { return "Logs out of the Mac at once." }
            if flags == [.command, .control] { return "Locks the screen." }
        case .named(.escape):
            if flags == [.command, .option] { return "Opens Force Quit." }
        case .named(.delete):
            if flags == [.command] { return "Deletes the selected item (in Finder, moves it to the Trash)." }
            if flags == [.command, .shift] { return "Empties the Trash." }
            if flags == [.command, .shift, .option] { return "Empties the Trash without asking." }
        default:
            break
        }
        return nil
    }
}
