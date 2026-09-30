import AppKit
import CoreGraphics
import Foundation
import Testing
import VoxaCore
@testable import VoxaHUD
import VoxaTestSupport

/// Real-window tests for what the Voxa bar shows while a command runs: progress, the reply, and the question, in the same panel as
/// the field, and what that means for the keyboard and the clicks. See `CommandBarWindowTests` for why these run the run loop.
@MainActor
@Suite("CommandBarController showing a command", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct CommandBarCommandTests {
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

    @Test("a command that has the bar showing keeps it there without the keyboard or the clicks, and it goes when the command is over")
    func aCommandKeepsTheBarShowingItself() async throws {
        let bar = makeBar()
        bar.open()
        #expect(await hasKeyboard(bar))

        // What the app does when a typed command starts: begin the session, hand the keyboard back, show the progress.
        bar.beginSession()
        bar.setTranscript("open Safari", isFinal: true)
        bar.releaseKeyboard()
        bar.show(.thinking(partial: nil))
        await pump(0.2)

        #expect(bar.isVisible && bar.mode == .thinking(partial: nil), "the command's progress is shown in the bar itself")
        #expect(!bar.hasKeyboard && !bar.panelCanBecomeKey, "what the command types must reach the app in front")
        #expect(bar.panelIgnoresMouseEvents, "clicks go through to the app underneath")
        #expect(!bar.model.isOpen)

        bar.show(.reply("Done."))
        bar.hide(after: nil)
        #expect(await waitUntil(timeout: .seconds(3)) { !bar.isVisible }, "a bar that was only showing the command goes when it is over")
    }

    @Test("a command shows in the bar even though nobody opened it, and the bar goes when that is over")
    func aCommandShowsWithoutTheBarBeingOpened() async throws {
        let bar = makeBar()
        bar.beginSession()
        bar.show(.thinking(partial: nil))
        await pump()

        #expect(bar.isVisible && !bar.model.isOpen)
        #expect(bar.panelIgnoresMouseEvents, "the bar isn't the person's, so clicks pass through it")
        #expect(!bar.panelCanBecomeKey)

        bar.hide(after: nil)
        #expect(await waitUntil(timeout: .seconds(3)) { !bar.isVisible }, "the bar goes when the command is over")
    }

    @Test("a confirmation card accepts clicks and never takes keyboard focus from the app underneath")
    func confirmationIsClickableButNotKey() async throws {
        let bar = makeBar()
        bar.show(.listening)
        await pump()
        #expect(bar.panelIgnoresMouseEvents == true, "clicks pass through a bar that only shows a command")

        bar.show(.confirm(question))
        await pump()
        #expect(bar.panelIgnoresMouseEvents == false, "the buttons must be clickable")
        #expect(bar.panelCanBecomeKey == false, "the panel must not steal typing focus")

        bar.show(.reply("Done."))
        await pump()
        #expect(bar.panelIgnoresMouseEvents == true, "clicks pass through again once the question is gone")
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("a question is never a place a keystroke can land, even in a bar the person has open")
    func openBarCannotTakeKeysWhileAsking() async throws {
        let bar = makeBar()
        bar.keepsOpen = { true }
        bar.open()
        #expect(await hasKeyboard(bar))

        bar.beginSession()
        bar.show(.confirm(question))
        #expect(!bar.hasKeyboard, "whatever had the keyboard gives it up as the question appears")
        #expect(!bar.panelCanBecomeKey, "the question is showing: the bar can't have the keyboard")
        #expect(!bar.panelIgnoresMouseEvents)
        bar.keepsOpen = { false }
        bar.hide(after: nil)
        bar.close()
        await pump(0.4)
    }

    @Test("the buttons of a question reach whoever is asking")
    func questionButtons() {
        let bar = makeBar()
        var chosen: [ConfirmationChoice] = []
        bar.onConfirmationChoice = { chosen.append($0) }
        bar.pressConfirmationButton(.allow)
        bar.pressConfirmationButton(.deny)
        #expect(chosen == [.allow, .deny])
    }

    @Test("putting the bar away does not take a question off the screen")
    func closingKeepsTheQuestion() async throws {
        let bar = makeBar()
        bar.open()
        bar.beginSession()
        bar.show(.confirm(question))
        await pump()

        bar.close()
        #expect(bar.isVisible, "the command is still waiting for an answer, and the person has to be able to see what it is")
        #expect(bar.mode == .confirm(question))
        #expect(!bar.model.isOpen)
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("opening the bar while a command runs says why it can't be typed into, and leaves the command showing")
    func openingWhileBusy() async throws {
        let bar = makeBar()
        bar.beginSession()
        bar.show(.thinking(partial: nil))
        await pump()

        bar.open()
        #expect(bar.model.note == L10n.Bar.busyNote)
        #expect(bar.mode == .thinking(partial: nil))
        #expect(!bar.model.isOpen && !bar.hasKeyboard && !bar.panelCanBecomeKey)
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("opening the bar clears an answer that was left showing, and takes the keyboard")
    func openingClearsAnAnswer() async throws {
        let bar = makeBar()
        bar.beginSession()
        bar.show(.reply("Done."))
        await pump()

        bar.open()
        #expect(bar.mode == .idle && bar.model.isOpen)
        #expect(await hasKeyboard(bar))
        bar.close()
    }

    @Test("when a command is over, a bar the person has open goes back to waiting for the next; it doesn't go away")
    func openBarWaitsAgain() async throws {
        let bar = makeBar()
        bar.open()
        bar.show(.thinking(partial: nil))
        bar.show(.reply("Done."))
        bar.hide(after: nil)
        await pump(0.4)

        #expect(bar.isVisible && bar.mode == .idle && bar.model.isOpen)
        #expect(bar.panelCanBecomeKey, "it can be typed into again")
        bar.close()
    }

    @Test("a listening bar goes back to waiting when a command is over, even though the command took the bar from the person")
    func listeningBarWaitsAgain() async throws {
        let bar = makeBar()
        bar.keepsOpen = { true }
        bar.open()
        bar.beginSession()
        bar.releaseKeyboard()
        bar.show(.acting(title: "Open Safari"))
        #expect(bar.model.isOpen, "the microphone is on, so the bar is still the person's")

        bar.hide(after: nil)
        await pump(0.4)
        #expect(bar.isVisible && bar.mode == .idle)
        bar.keepsOpen = { false }
        bar.close()
    }

    @Test("a delayed end is cancelled by whatever is shown next")
    func hideIsCancelled() async {
        let bar = makeBar()
        bar.show(.listening)
        bar.hide(after: .milliseconds(80))
        bar.show(.reply("still here"))
        await pump(0.5)
        #expect(bar.isVisible, "a new show must cancel the pending end")
        bar.hide(after: nil)
        await pump(0.4)
    }

    @Test("a reply ends by itself after its time, and the bar goes with it")
    func replyEnds() async {
        let bar = makeBar()
        bar.beginSession()
        bar.show(.reply("Done."))
        bar.hide(after: .milliseconds(80))
        #expect(await waitUntil(timeout: .seconds(3)) { !bar.isVisible }, "the reply's time runs out and the bar goes with it")
    }
}
