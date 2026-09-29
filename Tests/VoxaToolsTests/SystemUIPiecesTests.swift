import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import VoxaTestSupport
@testable import VoxaTools

// These cover the parts of the real system layer that can be checked without moving anyone's mouse or pressing a key: how
// events are *built* (nothing here posts one), how a character is found on the keyboard, and how the window list and the
// Accessibility API's answers are read. Whether events actually land is for the person to see, in the manual checks.

@Suite("Input events")
struct InputEventTests {
    @Test("short text is one run; a line break is the Return key and a tab is the Tab key")
    func breaks() {
        #expect(CGEventInputSynthesizer.pieces(of: "hello") == [.text("hello")])
        #expect(CGEventInputSynthesizer.pieces(of: "a\nb") == [.text("a"), .key(.return), .text("b")])
        #expect(CGEventInputSynthesizer.pieces(of: "a\r\nb") == [.text("a"), .key(.return), .text("b")])
        #expect(CGEventInputSynthesizer.pieces(of: "a\tb") == [.text("a"), .key(.tab), .text("b")])
        #expect(CGEventInputSynthesizer.pieces(of: "\n") == [.key(.return)])
        #expect(CGEventInputSynthesizer.pieces(of: "").isEmpty)
    }

    @Test("long text is cut into runs a key event can carry, and nothing is lost")
    func chunks() {
        let text = String(repeating: "a", count: 45)
        let pieces = CGEventInputSynthesizer.pieces(of: text)
        #expect(
            pieces == [
                .text(String(repeating: "a", count: 20)), .text(String(repeating: "a", count: 20)),
                .text(String(repeating: "a", count: 5)),
            ])
        let joined = pieces.compactMap { piece -> String? in if case .text(let string) = piece { string } else { nil } }.joined()
        #expect(joined == text)
    }

    @Test("a character made of several units is never split between two runs")
    func graphemes() {
        // Each family emoji is 11 UTF-16 units; two don't fit in a run of 20, so they go in separate runs, whole.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.utf16.count == 11)
        let pieces = CGEventInputSynthesizer.pieces(of: family + family)
        #expect(pieces == [.text(family), .text(family)])
        let accented = String(repeating: "e\u{301}", count: 15)  // 30 units, each character 2
        for case .text(let run) in CGEventInputSynthesizer.pieces(of: accented) {
            #expect(run.utf16.count <= 20 && run.count == run.unicodeScalars.count / 2)
        }
    }

    @Test("modifiers become the matching event flags")
    func flags() {
        #expect(CGEventInputSynthesizer.flags(for: []).isEmpty)
        #expect(CGEventInputSynthesizer.flags(for: [.command]) == .maskCommand)
        #expect(CGEventInputSynthesizer.flags(for: [.command, .shift]) == [.maskCommand, .maskShift])
        #expect(
            CGEventInputSynthesizer.flags(for: [.option, .control, .function]) == [
                .maskAlternate, .maskControl, .maskSecondaryFn,
            ])
    }

    @Test("a key event carries its key code, its flags, and whether it is a press or a release")
    func keyEvents() throws {
        let source = CGEventSource(stateID: .privateState)
        let down = try #require(CGEventInputSynthesizer.keyEvent(source: source, code: 1, flags: .maskCommand, down: true))
        #expect(down.type == .keyDown)
        #expect(down.getIntegerValueField(.keyboardEventKeycode) == 1)
        #expect(down.flags.contains(.maskCommand))
        let up = try #require(CGEventInputSynthesizer.keyEvent(source: source, code: 1, flags: .maskCommand, down: false))
        #expect(up.type == .keyUp)
    }

    @Test("a mouse event carries its position, its button and how many clicks it is part of")
    func mouseEvents() throws {
        let source = CGEventSource(stateID: .privateState)
        let point = CGPoint(x: 412, y: 133)
        let down = try #require(
            CGEventInputSynthesizer.mouseEvent(source: source, type: .leftMouseDown, point: point, button: .left, clickState: 2))
        #expect(down.type == .leftMouseDown && down.location == point)
        #expect(down.getIntegerValueField(.mouseEventClickState) == 2)
        let right = try #require(
            CGEventInputSynthesizer.mouseEvent(source: source, type: .rightMouseUp, point: point, button: .right, clickState: 1))
        #expect(right.type == .rightMouseUp)
        #expect(CGEventInputSynthesizer.pressTypes(for: .left) == [.leftMouseDown, .leftMouseUp])
        #expect(CGEventInputSynthesizer.pressTypes(for: .right) == [.rightMouseDown, .rightMouseUp])
    }

    @Test("Unicode text is carried in the event, not typed through key codes")
    func unicode() throws {
        let source = CGEventSource(stateID: .privateState)
        let event = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        let units = Array("héllo 你好".utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        var length = 0
        var read = [UniChar](repeating: 0, count: 32)
        event.keyboardGetUnicodeString(maxStringLength: 32, actualStringLength: &length, unicodeString: &read)
        #expect(String(utf16CodeUnits: Array(read.prefix(length)), count: length) == "héllo 你好")
    }
}

@Suite("Keyboard layout")
@MainActor
struct KeyboardLayoutTests {
    @Test("every letter and digit is found on the current layout, each on its own key")
    func lettersAndDigits() throws {
        let map = KeyboardLayoutMap.shared
        for character in "abcdefghijklmnopqrstuvwxyz0123456789" {
            #expect(map.lookup(character) != nil, "“\(character)” should be on the keyboard")
        }
        let letters = "abcdefghijklmnopqrstuvwxyz".compactMap { map.lookup($0)?.code }
        #expect(Set(letters).count == 26)
    }

    @Test("a common symbol can be found, with or without Shift")
    func symbols() {
        let map = KeyboardLayoutMap.shared
        for character in ",./;'-=[]\\`" {
            #expect(map.lookup(character) != nil, "“\(character)”")
        }
    }

    @Test("something that isn't on the keyboard isn't found")
    func absent() {
        #expect(KeyboardLayoutMap.shared.lookup("你") == nil)
    }

    @Test("the fallback keyboard covers letters and digits with a different key for each")
    func fallback() {
        let table = KeyboardLayoutMap.fallback
        for character in "abcdefghijklmnopqrstuvwxyz0123456789" {
            #expect(table[character] != nil, "“\(character)”")
        }
        #expect(table["?"]?.needsShift == true && table["/"]?.needsShift == false)
        #expect(table["?"]?.code == table["/"]?.code)
        let unshifted = table.filter { !$0.value.needsShift }.map(\.value.code)
        #expect(Set(unshifted).count == unshifted.count)
    }
}

@Suite("Window list")
struct WindowListTests {
    private func info(
        pid: Int = 42,
        number: Int = 7,
        alpha: Double = 1,
        layer: Int = 0,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: Int32(pid), kCGWindowNumber as String: UInt32(number), kCGWindowAlpha as String: alpha,
            kCGWindowLayer as String: layer, kCGWindowBounds as String: CGRectCreateDictionaryRepresentation(bounds),
        ]
    }

    @Test("an ordinary window is read as its owner, number and bounds")
    func ordinary() {
        let hit = SystemWindowList.hit(from: info())
        #expect(hit == WindowHit(pid: 42, windowID: 7, frame: CGRect(x: 10, y: 20, width: 300, height: 200)))
    }

    @Test("floating panels and pop-up menus count, because a click would land on them")
    func floating() {
        #expect(SystemWindowList.hit(from: info(layer: 3)) != nil)
        #expect(SystemWindowList.hit(from: info(layer: 101)) != nil)
    }

    @Test("invisible windows, desktop pictures and windows without an area don't count")
    func ignored() {
        #expect(SystemWindowList.hit(from: info(alpha: 0)) == nil)
        #expect(SystemWindowList.hit(from: info(layer: -2_147_483_600)) == nil)
        #expect(SystemWindowList.hit(from: info(bounds: CGRect(x: 0, y: 0, width: 0, height: 50))) == nil)
        #expect(SystemWindowList.hit(from: [:]) == nil)
    }
}

@Suite("Window list: a real window", .serialized, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
@MainActor
struct RealWindowListTests {
    @Test("the window server reports a window of this process, at the top, with the bounds it was given")
    func finds() async throws {
        await WindowTestLock.shared.acquire()
        defer { WindowTestLock.shared.release() }
        _ = NSApplication.shared
        let frame = NSRect(x: 240, y: 240, width: 320, height: 200)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // Swift owns it; AppKit releasing it as well would be a double release
        window.level = .screenSaver
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))

        let list = SystemWindowList()
        let id = UInt32(window.windowNumber)
        let byID = try #require(list.window(withID: id))
        #expect(byID.pid == getpid())
        #expect(byID.frame.width == window.frame.width && byID.frame.height == window.frame.height)

        // The centre of the window, in the window server's coordinates (origin at the top left of the main display).
        let center = CGPoint(x: byID.frame.midX, y: byID.frame.midY)
        let top = try #require(list.topWindow(at: center))
        #expect(top.pid == getpid() && top.windowID == id)

        window.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(list.window(withID: id) == nil, "a closed window is gone")
    }
}

@Suite("Accessibility API answers")
struct AccessibilityConversionTests {
    @Test("text comes from a string or an attributed string, and nothing else")
    func strings() {
        #expect(SystemAccessibilityTree.string("Save") == "Save")
        #expect(SystemAccessibilityTree.string(NSAttributedString(string: "Save")) == "Save")
        #expect(SystemAccessibilityTree.string(3 as NSNumber) == nil)
    }

    @Test("a value is its text, or a number written out, but a yes or no is not a value")
    func values() {
        #expect(SystemAccessibilityTree.valueText("hello") == "hello")
        #expect(SystemAccessibilityTree.valueText(1 as NSNumber) == "1")
        #expect(SystemAccessibilityTree.valueText(0.5 as NSNumber) == "0.5")
        #expect(SystemAccessibilityTree.valueText(true as NSNumber) == nil)
        #expect(SystemAccessibilityTree.valueText(kCFBooleanFalse as Any) == nil)
    }

    @Test("a position and a size are read out of the values the API wraps them in")
    func geometry() throws {
        var point = CGPoint(x: 12, y: 34)
        var size = CGSize(width: 56, height: 78)
        let pointValue = try #require(AXValueCreate(.cgPoint, &point))
        let sizeValue = try #require(AXValueCreate(.cgSize, &size))
        #expect(SystemAccessibilityTree.point(pointValue) == CGPoint(x: 12, y: 34))
        #expect(SystemAccessibilityTree.size(sizeValue) == CGSize(width: 56, height: 78))
        #expect(SystemAccessibilityTree.point(sizeValue) == nil, "a size is not a position")
        #expect(SystemAccessibilityTree.size(pointValue) == nil)
        #expect(SystemAccessibilityTree.point("nope") == nil)
    }

    @Test("without Accessibility access, another app's windows can't be read: every call comes back empty, and none crashes")
    func withoutPermission() throws {
        let tree = SystemAccessibilityTree()
        // A developer's own terminal may hold the permission; then there is nothing to check. (A process may always read its
        // *own* windows, which is why this asks about another app: Finder is always running.)
        guard !AXIsProcessTrusted() else { return }
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        let pid = try #require(finder?.processIdentifier)
        #expect(tree.focusedWindow(pid: pid) == nil)
        #expect(tree.menuBar(pid: pid) == nil)
        #expect(tree.focusedElement(pid: pid) == nil)
        #expect(tree.defaultButton(pid: pid) == nil)
        #expect(tree.element(atX: 10, y: 10, pid: pid) == nil)
        let unknown = AXHandle(9_999)
        #expect(tree.node(unknown) == nil)
        #expect(tree.children(unknown).isEmpty)
        #expect(!tree.press(unknown) && !tree.showMenu(unknown) && !tree.focus(unknown))
    }
}
