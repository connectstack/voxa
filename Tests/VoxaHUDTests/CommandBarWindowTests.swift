import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import VoxaCore
@testable import VoxaHUD
import VoxaTestSupport

/// Real-window tests for the Voxa bar. They run the run loop for the reasons `SettingsWindowTests` gives: window resizing during
/// AppKit's layout pass is a crash on macOS 26, and only a live display cycle exercises it.
@MainActor
@Suite("CommandBarController window", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct CommandBarWindowTests {
    private let longTranscript = "Open Safari and search for the best restaurants near me that are open late tonight and have "
        + "vegetarian options and outdoor seating, then add the top result to my calendar"

    private let question = BarWindowFixture.question

    private func makeBar(_ activation: FakeKeyboardActivation = FakeKeyboardActivation()) -> CommandBarController {
        BarWindowFixture.makeBar(activation)
    }

    private func pump(_ seconds: TimeInterval = 0.3) async {
        await BarWindowFixture.pump(seconds)
    }

    private func hasKeyboard(_ bar: CommandBarController) async -> Bool {
        await BarWindowFixture.hasKeyboard(bar)
    }

    private func key(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    // MARK: Where it is

    @Test("opening it shows a panel at the top centre, below the menu bar, that can take typing without activating the app")
    func showsAtTheTopCentre() async throws {
        let bar = makeBar()
        bar.open()
        await pump()
        defer { bar.close() }

        let window = try #require(bar.window)
        #expect(bar.isVisible)
        #expect(window.styleMask.contains(.nonactivatingPanel), "the app underneath must stay the front app")
        #expect(window.canBecomeKey, "the field has to be able to take typing")
        #expect(window.level == .statusBar)

        let frame = try #require(bar.panelFrame)
        let screen = try #require(bar.anchorVisibleFrame)
        #expect(frame.width == CommandBarView.width)
        #expect(abs(frame.midX - screen.midX) <= 1)
        #expect(abs(frame.maxY - (screen.maxY - 14)) <= 1, "14 pt below the menu bar")
    }

    @Test("resizing keeps the top edge pinned and the panel centered, whatever the content height")
    func resizeKeepsTopPinned() async throws {
        let bar = makeBar()
        bar.beginSession()
        bar.show(.listening)
        await pump()

        // The content reports its size through the view's preference; drive that path directly, since the SwiftUI layout itself isn't
        // reliable in a test process.
        bar.contentSizeDidChange(CGSize(width: CommandBarView.width, height: 127))
        let first = try #require(bar.panelFrame)
        let screen = try #require(bar.anchorVisibleFrame)

        for height: CGFloat in [187, 66, 110, 97, 240, 66] {
            bar.contentSizeDidChange(CGSize(width: CommandBarView.width, height: height))
            let frame = try #require(bar.panelFrame)
            #expect(frame.width == CommandBarView.width)
            #expect(frame.height == height, "expected \(height), got \(frame.height)")
            #expect(frame.maxY == first.maxY, "the top edge must stay pinned (height \(height))")
            #expect(abs(frame.midX - screen.midX) <= 1, "not centered at height \(height)")
            #expect(abs(frame.maxY - (screen.maxY - 14)) <= 1, "should sit 14 pt below the menu bar")
        }
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("it grows down, not up, when something appears under the field: the top edge stays pinned")
    func growsDownward() async throws {
        let bar = makeBar()
        bar.open()
        await pump()
        defer { bar.close() }
        let before = try #require(bar.panelFrame)

        bar.contentSizeDidChange(CGSize(width: CommandBarView.width, height: before.height + 40))
        let after = try #require(bar.panelFrame)
        #expect(after.height == before.height + 40)
        #expect(after.maxY == before.maxY)
    }

    @Test("a zero or negative reported size is ignored")
    func ignoresDegenerateSizes() async throws {
        let bar = makeBar()
        bar.beginSession()
        await pump()
        bar.contentSizeDidChange(CGSize(width: CommandBarView.width, height: 100))
        let before = try #require(bar.panelFrame)

        bar.contentSizeDidChange(.zero)
        bar.contentSizeDidChange(CGSize(width: CommandBarView.width, height: 0))
        bar.contentSizeDidChange(CGSize(width: -1, height: 50))
        #expect(bar.panelFrame == before)
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("the very first appearance is already centered (not positioned from a zero-sized window)")
    func firstAppearance() async throws {
        let bar = makeBar()
        bar.beginSession()
        await pump()
        let frame = try #require(bar.panelFrame)
        let screen = try #require(bar.anchorVisibleFrame)
        #expect(abs(frame.midX - screen.midX) <= 1, "panel midX \(frame.midX) vs screen midX \(screen.midX)")
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("hundreds of rapid state changes with layout running never crash")
    func stress() async {
        let bar = makeBar()
        let error = UserFacingError(
            title: "Microphone access is off",
            detail: "Turn it on in System Settings.",
            recovery: .openAppSettings
        )
        let modes: [HUDMode] = [
            .listening,
            .transcribing,
            .result("Set a timer"),
            .notice(title: "Hmm", detail: "Try again."),
            .error(error),
            .confirm(question),
            .thinking(partial: "Let me"),
            .reply("Done."),
        ]

        bar.beginSession()
        for step in 0..<150 {
            bar.show(modes[step % modes.count])
            bar.setTranscript(step.isMultiple(of: 3) ? longTranscript : "short", isFinal: step.isMultiple(of: 2))
            bar.push(level: AudioLevel(rms: Float(step % 10) / 10, peak: 1))
            await pump(0.004)
        }
        await pump(0.3)
        #expect(bar.isVisible)
        bar.hide(after: nil)
        #expect(await waitUntil(timeout: .seconds(3)) { !bar.isVisible })
    }

    // MARK: Being opened, and put away

    @Test("it tells the app how loud the microphone is")
    func level() {
        let bar = makeBar()
        #expect(bar.level == 0)
        bar.push(level: AudioLevel(rms: 0.5, peak: 0.9))
        #expect(bar.level == 0.5)
    }

    @Test("putting it away hides it and forgets what was typed")
    func closes() async {
        let bar = makeBar()
        bar.open()
        await pump()
        bar.model.text = "open Safari"
        bar.close()
        #expect(!bar.isVisible)
        #expect(bar.model.text.isEmpty)
        #expect(!bar.model.isOpen)
    }

    @Test("clicking elsewhere puts it away, unless it is listening")
    func resigningKey() async throws {
        let bar = makeBar()
        bar.open()
        await pump()
        try #require(bar.window).resignKey()
        await pump(0.1)
        #expect(!bar.isVisible, "a bar that isn't listening goes when the person clicks elsewhere")

        bar.keepsOpen = { true }
        bar.open()
        await pump()
        try #require(bar.window).resignKey()
        await pump(0.1)
        #expect(bar.isVisible, "a listening bar stays, so that the microphone is always visibly on")
        bar.keepsOpen = { false }
        bar.close()
    }

    @Test("it opens ready for typing: the field has the keyboard, and typed keys reach the model")
    func typing() async throws {
        let bar = makeBar()
        bar.open()
        defer { bar.close() }
        let window = try #require(bar.window)
        #expect(await hasKeyboard(bar), "the bar must be the key window to take typing")
        #expect(await waitUntil { window.firstResponder is NSTextView }, "the field's editor should hold the focus")

        for character in "open" {
            window.sendEvent(key(String(character), in: window))
        }
        await pump(0.1)
        #expect(bar.model.text == "open")
    }

    @Test("Return sends the command, and Esc puts the bar away")
    func returnAndEscape() async throws {
        let bar = makeBar()
        var sent: [String] = []
        var closed = 0
        bar.model.onSubmit = { sent.append($0); return true }
        bar.model.onClose = { closed += 1 }
        bar.open()
        defer { bar.close() }
        let window = try #require(bar.window)
        let ready = await hasKeyboard(bar)
        let focused = await waitUntil { window.firstResponder is NSTextView }
        #expect(ready && focused, "the bar has the keyboard (\(ready)) and its field has the focus (\(focused))")

        for character in "hi" { window.sendEvent(key(String(character), in: window)) }
        window.sendEvent(key("\r", code: 36, in: window))
        await pump(0.1)
        #expect(sent == ["hi"])

        window.sendEvent(key("\u{1B}", code: 53, in: window))
        await pump(0.1)
        #expect(closed == 1)
    }

    @Test("⌘A works in the field although a menu-bar app has no Edit menu")
    func selectAll() async throws {
        let bar = makeBar()
        bar.open()
        defer { bar.close() }
        let window = try #require(bar.window)
        let ready = await hasKeyboard(bar)
        let focused = await waitUntil { window.firstResponder is NSTextView }
        #expect(ready && focused, "the bar has the keyboard (\(ready)) and its field has the focus (\(focused))")
        for character in "open" { window.sendEvent(key(String(character), in: window)) }
        await pump(0.1)

        let handled = window.performKeyEquivalent(with: key("a", code: 0, flags: .command, in: window))
        #expect(handled)
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.selectedRange.length == 4, "all four letters selected")
    }

    @Test("once the bar really has the keyboard it makes Voxa the active app, and it gives that up again when it goes")
    func activation() async throws {
        let fake = FakeKeyboardActivation()
        let bar = makeBar(fake)
        bar.open()
        #expect(await hasKeyboard(bar))
        #expect(fake.isActive && fake.activations == 1, "typing goes to the active app, so the bar asks to be it")

        bar.close()
        #expect(!fake.isActive && fake.deactivations == 1, "and hands the keyboard back when it goes")
    }

    // MARK: The keyboard, while a command runs

    @Test("when a command starts the bar gives the keyboard back, and a bar with nothing to show goes")
    func releasesTheKeyboard() async throws {
        let bar = makeBar()
        bar.open()
        #expect(await hasKeyboard(bar))

        bar.releaseKeyboard()
        await pump(0.2)
        #expect(!bar.hasKeyboard)
        #expect(!bar.isVisible, "with the microphone off and no command to show, there is nothing for the bar to be")
    }

    @Test("a listening bar stays where it can be seen, but without the keyboard, so keystrokes a command makes reach the app in front")
    func listeningBarStaysWithoutTheKeyboard() async throws {
        let bar = makeBar()
        bar.keepsOpen = { true }
        bar.open()
        #expect(await hasKeyboard(bar))

        bar.releaseKeyboard()
        await pump(0.2)
        #expect(bar.isVisible)
        #expect(!bar.hasKeyboard, "typed keys must not land in the bar's field while a command types into another app")
        bar.keepsOpen = { false }
        bar.close()
    }

    @Test("giving the keyboard back when the bar doesn't have it does nothing")
    func releaseWithoutKeyboard() async {
        let bar = makeBar()
        bar.releaseKeyboard()
        #expect(!bar.isVisible)
    }
}
