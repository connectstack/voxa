import Foundation
import Testing
import VoxaCore
@testable import VoxaHUD

@MainActor
@Suite("CommandBarModel")
struct CommandBarModelTests {
    // MARK: Typing

    @Test("Return sends what was typed, trimmed, and clears the field")
    func submit() {
        let model = CommandBarModel()
        var sent: [String] = []
        model.onSubmit = { sent.append($0); return true }
        model.text = "  open Safari \n"
        model.submit()
        #expect(sent == ["open Safari"])
        #expect(model.text.isEmpty && model.note == nil)
    }

    @Test("nothing typed sends nothing")
    func emptySubmit() {
        let model = CommandBarModel()
        var calls = 0
        model.onSubmit = { _ in calls += 1; return true }
        for text in ["", "   ", "\n\t"] {
            model.text = text
            model.submit()
        }
        #expect(calls == 0)
    }

    @Test("a command that can't be taken (Voxa is busy) stays in the field, with a line that says so")
    func busy() {
        let model = CommandBarModel()
        model.onSubmit = { _ in false }
        model.text = "open Notes"
        model.submit()
        #expect(model.text == "open Notes")
        #expect(model.note == L10n.Bar.busyNote)
        #expect(model.lines.first == CommandBarModel.Line(text: L10n.Bar.busyNote, tone: .plain))
    }

    @Test("a new try clears the last line")
    func newTryClearsTheNote() {
        let model = CommandBarModel()
        model.onSubmit = { _ in false }
        model.text = "open Notes"
        model.submit()
        model.onSubmit = { _ in true }
        model.submit()
        #expect(model.note == nil && model.text.isEmpty)
    }

    // MARK: The microphone and Esc

    @Test("the microphone button asks the app to start or send, and clears the last line")
    func microphone() {
        let model = CommandBarModel()
        var clicks = 0
        model.onMicrophone = { clicks += 1 }
        model.note = "Voxa is busy. Press Esc to stop it."
        model.microphoneClicked()
        #expect(clicks == 1 && model.note == nil)
        model.microphoneClicked()
        #expect(clicks == 2, "each click is the app's to read: the first starts, the next sends")
    }

    @Test("a click with nobody to hear it does nothing")
    func microphoneWithoutAnApp() {
        let model = CommandBarModel()
        model.microphoneClicked()
        #expect(model.note == nil)
    }

    @Test("Esc asks the app to put the bar away")
    func escape() {
        let model = CommandBarModel()
        var closed = 0
        model.onClose = { closed += 1 }
        model.escape()
        #expect(closed == 1)
    }

    @Test("asking for focus is counted, so the view can react to each one")
    func focus() {
        let model = CommandBarModel()
        model.requestFocus()
        model.requestFocus()
        #expect(model.focusRequests == 2)
    }

    // MARK: What it says

    @Test("with nothing to say there is nothing under the field")
    func noLines() {
        #expect(CommandBarModel().lines.isEmpty)
    }

    @Test("the lines under the field are why something didn't happen, then the warning about full control")
    func lines() {
        let model = CommandBarModel()
        model.warning = { L10n.Bar.fullControlWarning }
        #expect(model.lines == [CommandBarModel.Line(text: L10n.Bar.fullControlWarning, tone: .warning)])

        model.note = "Voxa is busy."
        #expect(model.lines.map(\.text) == ["Voxa is busy.", L10n.Bar.fullControlWarning], "what stopped it comes first")

        model.warning = { nil }
        #expect(model.lines == [CommandBarModel.Line(text: "Voxa is busy.", tone: .plain)])
    }

    // MARK: Putting away

    @Test("putting the bar away forgets what was typed and the line")
    func reset() {
        let model = CommandBarModel()
        model.text = "open Safari"
        model.note = "Voxa is busy."
        model.reset()
        #expect(model.text.isEmpty && model.note == nil)
    }

    @Test("a bare model is open, so that it draws its field and microphone")
    func opensByDefault() {
        #expect(CommandBarModel().isOpen)
    }
}
