import Foundation
import Testing
@testable import VoxaTools

@Suite("KeyChord")
struct KeyChordTests {
    @Test("shortcuts are read in any case, with the modifiers first and the key last", arguments: [
        ("cmd+s", KeyChord(key: .character("s"), modifiers: [.command])),
        ("Command+S", KeyChord(key: .character("s"), modifiers: [.command])),
        ("⌘+shift+4", KeyChord(key: .character("4"), modifiers: [.command, .shift])),
        ("ctrl+alt+left", KeyChord(key: .named(.left), modifiers: [.control, .option])),
        ("option+delete", KeyChord(key: .named(.delete), modifiers: [.option])),
        ("  cmd + t  ", KeyChord(key: .character("t"), modifiers: [.command])),
        ("return", KeyChord(key: .named(.return))),
        ("Enter", KeyChord(key: .named(.return))),
        ("esc", KeyChord(key: .named(.escape))),
        ("f5", KeyChord(key: .named(.f5))),
        ("fn+f11", KeyChord(key: .named(.f11), modifiers: [.function])),
        ("pagedown", KeyChord(key: .named(.pageDown))),
        ("a", KeyChord(key: .character("a"))),
        ("/", KeyChord(key: .character("/"))),
        ("cmd+plus", KeyChord(key: .character("+"), modifiers: [.command])),
        ("cmd++", KeyChord(key: .character("+"), modifiers: [.command])),
        ("+", KeyChord(key: .character("+"))),
        ("cmd+minus", KeyChord(key: .character("-"), modifiers: [.command])),
        ("cmd+,", KeyChord(key: .character(","), modifiers: [.command])),
    ])
    func parses(text: String, expected: KeyChord) throws {
        #expect(try KeyChord.parse(text) == expected)
    }

    @Test("text that isn't a key is refused with a message the model can act on", arguments: [
        "", "   ", "cmd+", "cmd+shift", "hyper+s", "cmd+banana", "cmd+ab", "foo",
    ])
    func refuses(text: String) {
        #expect(throws: KeyChord.ParseError.self) { try KeyChord.parse(text) }
    }

    @Test("the message names the part that was wrong")
    func message() {
        do {
            _ = try KeyChord.parse("hyper+s")
            Issue.record("should have thrown")
        } catch let error as KeyChord.ParseError {
            #expect(error.message.contains("'hyper'") && error.message.contains("cmd, shift"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        do {
            _ = try KeyChord.parse("cmd+banana")
            Issue.record("should have thrown")
        } catch let error as KeyChord.ParseError {
            #expect(error.message.contains("'banana'") && error.message.contains("pagedown"))
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test("a chord is shown the way a menu shows it")
    func display() throws {
        #expect(try KeyChord.parse("cmd+s").displayString == "⌘S")
        #expect(try KeyChord.parse("cmd+shift+4").displayString == "⇧⌘4")
        #expect(try KeyChord.parse("ctrl+opt+cmd+left").displayString == "⌃⌥⌘←")
        #expect(try KeyChord.parse("return").displayString == "Return")
        #expect(try KeyChord.parse("esc").displayString == "Esc")
        #expect(try KeyChord.parse("fn+f5").displayString == "fn F5")
    }

    @Test("shortcuts that quit, log out, delete or empty the Trash say what they do")
    func consequences() throws {
        let cases: [(String, String)] = [
            ("cmd+q", "Quits the app"), ("cmd+shift+q", "Logs out"), ("cmd+opt+shift+q", "Logs out of the Mac at once"),
            ("ctrl+cmd+q", "Locks the screen"), ("cmd+opt+esc", "Force Quit"), ("cmd+delete", "Deletes the selected item"),
            ("cmd+shift+delete", "Empties the Trash"), ("cmd+opt+shift+delete", "without asking"),
        ]
        for (text, expected) in cases {
            let reason = try #require(try KeyChord.parse(text).consequence, "\(text) should have a consequence")
            #expect(reason.contains(expected), "\(text): \(reason)")
        }
    }

    @Test("ordinary shortcuts and keys have no consequence to report", arguments: [
        "cmd+s", "cmd+c", "cmd+v", "cmd+w", "cmd+t", "cmd+z", "q", "delete", "cmd+shift+4", "return", "escape", "tab",
    ])
    func ordinary(text: String) throws {
        #expect(try KeyChord.parse(text).consequence == nil)
    }

    @Test("Return is recognised, and only a plain character counts as typing")
    func kinds() throws {
        #expect(try KeyChord.parse("return").isReturn)
        #expect(try KeyChord.parse("cmd+return").isReturn)
        #expect(try !KeyChord.parse("tab").isReturn)
        #expect(try KeyChord.parse("a").isTypedCharacter)
        #expect(try KeyChord.parse("shift+a").isTypedCharacter)
        #expect(try KeyChord.parse("option+a").isTypedCharacter)
        #expect(try !KeyChord.parse("cmd+a").isTypedCharacter, "a shortcut is not text")
        #expect(try !KeyChord.parse("ctrl+a").isTypedCharacter)
        #expect(try !KeyChord.parse("return").isTypedCharacter)
    }

    @Test("every named key has a distinct code, so no two keys would press the same physical key")
    func distinctCodes() {
        let codes = KeyChord.NamedKey.allCases.map(\.virtualKey)
        #expect(Set(codes).count == codes.count)
    }
}
