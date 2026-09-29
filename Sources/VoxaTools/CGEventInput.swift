import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// Mouse and keyboard input made with `CGEvent`, which lands in whichever app is in front. macOS delivers it only to an app
/// that has been given Accessibility access; without that the events are silently dropped, which is why `ui_*` tools ask
/// for the permission before anything is sent.
///
/// The events come from a private event source, so the state of the real keyboard (a key the person happens to be holding)
/// isn't mixed into them.
public struct CGEventInputSynthesizer: InputSynthesizing {
    /// A short gap between events: some apps drop events that arrive faster than they can take them.
    private let pace: Duration

    public init(pace: Duration = .milliseconds(8)) {
        self.pace = pace
    }

    // MARK: Clicking

    public func click(at point: CGPoint, button: MouseButton, clickCount: Int) async throws {
        let source = CGEventSource(stateID: .privateState)
        let original = CGEvent(source: nil)?.location
        guard let move = Self.mouseEvent(source: source, type: .mouseMoved, point: point, button: button, clickState: 0) else {
            throw UIAutomationError.failed("The click could not be made.")
        }
        move.post(tap: .cghidEventTap)
        try await Task.sleep(for: pace)

        for count in 1...max(1, min(clickCount, 3)) {
            for type in Self.pressTypes(for: button) {
                guard let event = Self.mouseEvent(source: source, type: type, point: point, button: button, clickState: count)
                else {
                    throw UIAutomationError.failed("The click could not be made.")
                }
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: pace)
            }
        }
        // Put the pointer back where the person left it.
        if let original {
            Self.mouseEvent(source: source, type: .mouseMoved, point: original, button: button, clickState: 0)?
                .post(tap: .cghidEventTap)
        }
    }

    static func pressTypes(for button: MouseButton) -> [CGEventType] {
        button == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp]
    }

    static func mouseEvent(
        source: CGEventSource?,
        type: CGEventType,
        point: CGPoint,
        button: MouseButton,
        clickState: Int
    ) -> CGEvent? {
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button == .left ? .left : .right
        )
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        return event
    }

    // MARK: Typing

    /// Text goes in as Unicode, in small pieces, so it comes out right on any keyboard layout and in any language. A line
    /// break or a tab is the Return or Tab key, which is what a person would press.
    public func type(_ text: String) async throws {
        let source = CGEventSource(stateID: .privateState)
        for piece in Self.pieces(of: text) {
            switch piece {
            case .text(let string):
                try post(unicode: string, source: source)
            case .key(let named):
                try post(code: named.virtualKey, flags: [], source: source)
            }
            try await Task.sleep(for: pace)
        }
    }

    enum Piece: Equatable {
        case text(String)
        case key(KeyChord.NamedKey)
    }

    /// Breaks text into runs of at most `limit` UTF-16 units (a key event can carry only a few), never splitting a character,
    /// with line breaks and tabs made into keys.
    static func pieces(of text: String, limit: Int = 20) -> [Piece] {
        var pieces: [Piece] = []
        var run = ""
        func flush() {
            if !run.isEmpty { pieces.append(.text(run)) }
            run = ""
        }
        for character in text {
            if character.isNewline {
                flush()
                pieces.append(.key(.return))
            } else if character == "\t" {
                flush()
                pieces.append(.key(.tab))
            } else {
                if run.utf16.count + String(character).utf16.count > limit { flush() }
                run.append(character)
            }
        }
        flush()
        return pieces
    }

    private func post(unicode string: String, source: CGEventSource?) throws {
        let units = Array(string.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else {
                throw UIAutomationError.failed("The text could not be typed.")
            }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Keys

    public func press(_ chords: [KeyChord]) async throws {
        let source = CGEventSource(stateID: .privateState)
        for chord in chords {
            guard let resolved = await Self.resolve(chord.key) else {
                throw UIAutomationError.failed("There is no key for “\(chord.displayString)” on the current keyboard layout.")
            }
            var flags = Self.flags(for: chord.modifiers)
            if resolved.needsShift { flags.insert(.maskShift) }
            try post(code: resolved.code, flags: flags, source: source)
            try await Task.sleep(for: pace * 4)
        }
    }

    private func post(code: UInt16, flags: CGEventFlags, source: CGEventSource?) throws {
        for down in [true, false] {
            guard let event = Self.keyEvent(source: source, code: code, flags: flags, down: down) else {
                throw UIAutomationError.failed("The key could not be pressed.")
            }
            event.post(tap: .cghidEventTap)
        }
    }

    static func keyEvent(source: CGEventSource?, code: UInt16, flags: CGEventFlags, down: Bool) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        return event
    }

    static func flags(for modifiers: KeyChord.Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// The key to press for `key`: fixed for a named key, found on the keyboard layout for a character.
    static func resolve(_ key: KeyChord.Key) async -> (code: UInt16, needsShift: Bool)? {
        switch key {
        case .named(let named):
            return (named.virtualKey, false)
        case .character(let character):
            return await MainActor.run { KeyboardLayoutMap.shared.lookup(character) }
        }
    }
}

// MARK: - Which key makes which character

/// Where a character is on the keyboard in use. A shortcut such as ⌘S is the *S key*, and which physical key that is depends
/// on the layout (on a French keyboard, A and Q swap places), so the key is found by asking the layout.
///
/// The layout used is the ASCII-capable one, the same one macOS matches shortcuts against, so shortcuts still work while the
/// input source is Japanese or Russian. The system calls involved must run on the main thread.
@MainActor
final class KeyboardLayoutMap {
    static let shared = KeyboardLayoutMap()

    private var layoutID: String?
    private var table: [Character: (code: UInt16, needsShift: Bool)] = [:]

    func lookup(_ character: Character) -> (code: UInt16, needsShift: Bool)? {
        refreshIfLayoutChanged()
        return table[character] ?? Self.fallback[character]
    }

    private func refreshIfLayoutChanged() {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        guard id != layoutID || table.isEmpty else { return }
        layoutID = id
        table = Self.build(from: source)
    }

    private static func build(from source: TISInputSource) -> [Character: (code: UInt16, needsShift: Bool)] {
        guard let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let layoutData = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        var table: [Character: (code: UInt16, needsShift: Bool)] = [:]
        // The unshifted meaning of a key wins over a shifted one, and the first key found wins over a later duplicate (the keypad).
        for shifted in [false, true] {
            for code in UInt16(0)..<128 where !KeyChord.NamedKey.allCases.contains(where: { $0.virtualKey == code }) {
                guard let character = translate(layoutData, code: code, shifted: shifted), table[character] == nil else {
                    continue
                }
                table[character] = (code, shifted)
            }
        }
        return table
    }

    /// The character a key produces on this layout, or nil for a dead key or a key with none.
    static func translate(_ layout: Data, code: UInt16, shifted: Bool) -> Character? {
        layout.withUnsafeBytes { raw -> Character? in
            guard let base = raw.baseAddress else { return nil }
            let keyLayout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shifted ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(
                keyLayout,
                code,
                UInt16(kUCKeyActionDown),
                modifiers,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length == 1, let scalar = Unicode.Scalar(characters[0]), !scalar.properties.isWhitespace else {
                return nil
            }
            return Character(scalar)
        }
    }

    /// A US keyboard, for when the layout can't be read.
    static let fallback: [Character: (code: UInt16, needsShift: Bool)] = {
        let plain: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
            ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21),
            ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31),
            ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42),
            (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
        ]
        let shifted: [(Character, UInt16)] = [
            ("!", 18), ("@", 19), ("#", 20), ("$", 21), ("^", 22), ("%", 23), ("+", 24), ("(", 25), ("&", 26), ("_", 27),
            ("*", 28), (")", 29), ("}", 30), ("{", 33), ("\"", 39), (":", 41), ("|", 42), ("<", 43), ("?", 44), (">", 47),
            ("~", 50),
        ]
        var table: [Character: (code: UInt16, needsShift: Bool)] = [:]
        for (character, code) in plain { table[character] = (code, false) }
        for (character, code) in shifted { table[character] = (code, true) }
        return table
    }()
}
