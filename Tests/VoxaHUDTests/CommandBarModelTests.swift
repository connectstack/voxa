import Foundation
import Testing
import VoxaCore
@testable import VoxaHUD

@MainActor
@Suite("CommandBarModel")
struct CommandBarModelTests {
    private let problem = UserFacingError(title: "Microphone access is off", detail: "Turn it on in System Settings.")

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

    @Test("the microphone button asks the app to switch listening, and clears the last line")
    func microphone() {
        let model = CommandBarModel()
        var toggles = 0
        model.onToggleListening = { toggles += 1 }
        model.note = "Stopped listening after 10 minutes of silence."
        model.toggleListening()
        #expect(toggles == 1 && model.note == nil)
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

    @Test("the field says what Voxa is doing while it is empty")
    func placeholder() {
        let model = CommandBarModel()
        let expected: [(HandsFreeState, String)] = [
            (.off, L10n.Bar.placeholder),
            (.starting, L10n.Bar.placeholderStarting),
            (.listening, L10n.Bar.placeholderListening),
            (.paused(.working), L10n.Bar.placeholderWorking),
            (.paused(.pushToTalk), L10n.Bar.placeholderWorking),
            (.paused(.speaking), L10n.Bar.placeholderSpeaking),
            (.unavailable(problem), problem.title),
        ]
        for (state, text) in expected {
            model.listening = state
            #expect(model.placeholder == text, "\(state)")
        }
    }

    @Test("with the microphone off there is nothing under the field")
    func noLinesWhenOff() {
        let model = CommandBarModel()
        model.warning = { "Full control is on" }
        #expect(model.lines.isEmpty, "the warning is about listening, so it waits for listening")
    }

    @Test("while listening the bar says what listening means, and warns about full control")
    func listeningLines() {
        let model = CommandBarModel()
        model.listening = .listening
        #expect(model.lines == [CommandBarModel.Line(text: L10n.Bar.listeningNote, tone: .plain)])

        model.warning = { L10n.Bar.fullControlWarning }
        #expect(model.lines.last == CommandBarModel.Line(text: L10n.Bar.fullControlWarning, tone: .warning))
        model.warning = { nil }
        #expect(model.lines.count == 1)
    }

    @Test("a microphone that can't be had says why, in red, and doesn't go on to describe listening")
    func unavailableLines() {
        let model = CommandBarModel()
        model.warning = { L10n.Bar.fullControlWarning }
        model.listening = .unavailable(problem)
        #expect(model.lines == [CommandBarModel.Line(text: problem.detail, tone: .problem)])
    }

    @Test("what stopped it comes first")
    func noteFirst() {
        let model = CommandBarModel()
        model.listening = .listening
        model.note = "Stopped."
        #expect(model.lines.first?.text == "Stopped.")
    }

    // MARK: Putting away

    @Test("putting the bar away forgets what was typed and the line, but not whether it is listening")
    func reset() {
        let model = CommandBarModel()
        model.text = "open Safari"
        model.note = "Voxa is busy."
        model.listening = .listening
        model.reset()
        #expect(model.text.isEmpty && model.note == nil)
        #expect(model.listening == .listening)
    }

    @Test("a bare model is open, so that it draws its field and microphone")
    func opensByDefault() {
        #expect(CommandBarModel().isOpen)
    }
}
