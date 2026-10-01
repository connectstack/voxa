import Foundation
import Testing
import VoxaAgent
@testable import VoxaApp
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaSpeech
import VoxaTestSupport

/// The Voxa bar's microphone button is the push-to-talk session started and ended by a click. These drive the real session with a
/// scripted recognizer and a manual clock, so what they check is the same code a held key runs.
@MainActor
@Suite("The microphone button: click to talk, click to send")
struct ClickToTalkTests {
    private func harness(agent: FakeAgent = FakeAgent(), confirmations: FakeConfirmations? = nil) -> (SessionHarness, FakeAgent) {
        (SessionHarness(agent: agent, confirmations: confirmations), agent)
    }

    // MARK: The happy path

    @Test("a click opens the microphone like a held key does, and shows how to send")
    func clickStarts() async {
        let (h, _) = harness()
        #expect(await h.clickAndListen())

        #expect(h.hud.beginCount == 1)
        #expect(h.hud.events.contains(.endsOnClick(true)), "the bar says to click the microphone to send, not to release a key")
        #expect(h.hud.modes.contains(.listening))
        #expect(h.controller.isMicrophoneOpen)
        #expect(h.controller.status == .listening)
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 1 }, "Esc cancels it")
    }

    @Test("the second click sends what was said to the agent, as letting go of the key does")
    func secondClickSends() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        await h.capture.emitChunk()
        await h.capture.emitChunk()
        #expect(await waitUntil { h.hud.events.contains(.transcript("open safari", isFinal: false)) }, "the words are shown as they come")

        await h.clickToSendAndFinishTail()

        #expect(await waitUntil { agent.commands == ["Open Safari."] })
        #expect(h.hud.modes.contains(.transcribing))
        #expect(await h.capture.stopCount >= 1)
        #expect(!h.controller.isMicrophoneOpen)
    }

    @Test("it listens until the click, however long nothing is said: nothing ends it but a click, Esc, or the recording limit")
    func nothingEndsItButAClick() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        await h.capture.emitChunk()

        h.clock.advance(by: .seconds(30))   // a long stretch with nobody clicking, but within the recording limit
        await settle()
        #expect(h.controller.phase == .listening)
        #expect(await h.capture.isCapturing)
        #expect(agent.commands.isEmpty, "a pause is not the end of what someone is saying")
        #expect(h.controller.isMicrophoneOpen)
    }

    @Test("nothing heard at all is a friendly notice that says how the button works, and the bar goes back to waiting")
    func nothingHeard() async {
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(ending: .completes(final: "  ")))
        #expect(await h.clickAndListen())
        await h.clickToSendAndFinishTail()

        #expect(await waitUntil { if case .notice = h.hud.lastMode { true } else { false } })
        guard case .notice(let title, let detail) = h.hud.lastMode else {
            Issue.record("expected a notice, got \(String(describing: h.hud.lastMode))")
            return
        }
        #expect(title == L10n.HUD.didntCatch)
        #expect(detail == L10n.HUD.didntCatchClickDetail)
        #expect(h.phase == .idle)
    }

    @Test("the click that sent it is never taken for an accidental tap: even a quick click and click sends")
    func quickClicksAreNotTaps() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        await h.clickToSendAndFinishTail()   // no time passed on the clock at all
        #expect(await waitUntil { agent.commands == ["Open Safari."] }, "it was sent, not dropped")
        #expect(!h.holdHintIsShowing, "'hold the shortcut' is for the key; a click has no hold")
    }

    // MARK: Changing one's mind

    @Test("Esc cancels it: the microphone is let go of, nothing is sent, and the bar goes back")
    func escapeCancels() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        await h.capture.emitChunk()
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 1 })

        h.hotkeys.pressEscape()

        #expect(await h.waitForPhase(.idle))
        #expect(await waitUntil { await !h.capture.isCapturing })
        #expect(await waitUntil { h.hud.isDismissed })
        #expect(agent.commands.isEmpty)
        #expect(!h.controller.isMicrophoneOpen)
    }

    @Test("a second click before it is listening is a change of mind: it cancels quietly, and nothing is said about it")
    func clickWhileStarting() async {
        let (h, agent) = harness()
        h.permissions.whileRequesting = { try? await Task.sleep(for: .milliseconds(150)) }
        h.permissions.statuses[.microphone] = .notDetermined
        h.controller.microphoneClicked()
        #expect(await waitUntil { h.controller.phase == .starting })

        h.controller.microphoneClicked()

        #expect(h.controller.phase == .idle)
        #expect(await waitUntil { h.hud.isDismissed })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await h.capture.startCount == 0, "the microphone was never opened")
        #expect(!h.modesContainNotice, "no hold-to-talk hint, no 'didn't catch that'")
        #expect(agent.commands.isEmpty)
    }

    @Test("putting the bar away lets go of the microphone the button opened, and sends nothing")
    func cancelMicrophone() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        await h.capture.emitChunk()

        h.controller.cancelMicrophone()

        #expect(h.controller.phase == .idle)
        #expect(await waitUntil { await !h.capture.isCapturing })
        #expect(!h.controller.isMicrophoneOpen)
        #expect(agent.commands.isEmpty)
    }

    @Test("putting the bar away does not stop a held key's command, or one that is being carried out")
    func cancelMicrophoneIsOnlyForTheButton() async {
        let (h, agent) = harness(agent: FakeAgent(.init(holds: true)))
        #expect(await h.pressAndListen())
        h.controller.cancelMicrophone()
        #expect(h.controller.phase == .listening, "the key's microphone is the key's")
        await h.holdLongEnough()
        await h.releaseAndFinishTail()
        #expect(await waitUntil { agent.commands.count == 1 })

        h.controller.cancelMicrophone()
        #expect(h.controller.status == .thinking, "the command goes on")
        agent.release()
    }

    // MARK: The key and the button share one microphone

    @Test("a held key's release does not end a session that a click started, and its press is ignored")
    func keyDoesNotEndAClick() async {
        let (h, _) = harness()
        #expect(await h.clickAndListen())

        h.hotkeys.press()
        await settle()
        #expect(await h.capture.startCount == 1)
        #expect(h.hud.beginCount == 1)

        await h.holdLongEnough()
        h.hotkeys.release()
        await settle()
        #expect(h.controller.phase == .listening, "only a click ends what a click began")
        #expect(h.controller.isMicrophoneOpen)
    }

    @Test("a click while a held key has the microphone does nothing, and the key's session is not hurt")
    func clickDoesNotEndAKey() async {
        let (h, agent) = harness()
        #expect(await h.pressAndListen())

        h.controller.microphoneClicked()
        await settle()
        #expect(h.controller.phase == .listening)
        #expect(!h.controller.isMicrophoneOpen, "it is not the button's microphone")
        #expect(await h.capture.startCount == 1)

        await h.capture.emitChunk()
        await h.holdLongEnough()
        await h.releaseAndFinishTail()
        #expect(await waitUntil { agent.commands == ["Open Safari."] })
    }

    // MARK: Questions

    @Test("a click while a command is being carried out does nothing")
    func clickWhileWorking() async {
        let (h, agent) = harness(agent: FakeAgent(.init(holds: true)))
        #expect(h.controller.submitCommand("open Safari"))
        #expect(await waitUntil { agent.commands.count == 1 })

        h.controller.microphoneClicked()
        await settle()
        #expect(await h.capture.startCount == 0)
        #expect(h.controller.phase == .idle)
        agent.release()
    }

    @Test("a click is never the answer to a question: only the key held records one")
    func clickCannotAnswer() async {
        let confirmations = FakeConfirmations()
        let (h, agent) = harness(agent: FakeAgent(.init(holds: true)), confirmations: confirmations)
        #expect(h.controller.submitCommand("delete my files"))
        #expect(await waitUntil { agent.commands.count == 1 })
        confirmations.isAwaitingAnswer = true

        h.controller.microphoneClicked()
        await settle()
        #expect(await h.capture.startCount == 0, "the microphone stays closed while a question is up")
        #expect(confirmations.answers.isEmpty)
        #expect(h.hud.lastAnswerStatus == nil)
        agent.release()
    }

    // MARK: Limits and failures

    @Test("a click that is never followed by another is ended by the recording limit, and what was said is sent")
    func recordingLimit() async {
        let (h, agent) = harness()
        h.settings.current.maxRecordingSeconds = 5
        #expect(await h.clickAndListen())
        await h.capture.emitChunk()
        _ = await waitUntil { h.clock.sleeperCount >= 1 }   // the limit

        h.clock.advance(by: .seconds(5))
        await settle()
        _ = await waitUntil { h.clock.sleeperCount >= 1 }
        h.clock.advance(by: .milliseconds(250))   // the release tail

        #expect(await waitUntil { agent.commands == ["Open Safari."] })
    }

    @Test("a denied microphone shows the fix-it error, and never opens the microphone")
    func microphoneDenied() async {
        let (h, _) = harness()
        h.permissions.statuses[.microphone] = .denied

        h.controller.microphoneClicked()
        #expect(await h.waitForPhase(.failed))

        #expect(h.hud.lastMode == .error(.permissionRequired(.microphone, status: .denied)))
        #expect(await h.capture.startCount == 0)
        #expect(!h.controller.isMicrophoneOpen)
    }

    @Test("a microphone that can't be had is reported once, not retried until it works")
    func noMicrophone() async {
        let (h, _) = harness()
        await h.capture.setStartError(AudioCaptureError.noInputDevice)

        h.controller.microphoneClicked()
        #expect(await h.waitForPhase(.failed))
        await settle()
        #expect(await h.capture.startCount == 1, "one click is one try")
    }

    // MARK: Afterwards

    @Test("a click after a result starts a fresh command")
    func clickAfterResult() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        await h.capture.emitChunk()
        await h.clickToSendAndFinishTail()
        #expect(await waitUntil { agent.commands.count == 1 })
        #expect(await waitUntil { h.hud.lastMode == .reply("Opened Safari.") })

        #expect(await h.clickAndListen())
        #expect(h.hud.beginCount == 2)
        #expect(await h.capture.startCount == 2)
    }

    @Test("a click while Voxa is speaking stops it talking, and listens")
    func clickStopsSpeech() async {
        let (h, _) = harness()
        h.speaker.speak("Opened Safari.", options: .init())
        #expect(h.controller.availability == .speaking)

        #expect(await h.clickAndListen())
        #expect(h.speaker.stopCount >= 1, "Voxa must not talk over the person, or let its own voice reach the microphone")
    }

    @Test("a typed or Siri command is not taken while the button has the microphone")
    func commandsWaitForTheMicrophone() async {
        let (h, agent) = harness()
        #expect(await h.clickAndListen())
        #expect(h.controller.availability == .listening)
        #expect(!h.controller.submitCommand("open Notes"))
        #expect(agent.commands.isEmpty)
    }
}

private extension SessionHarness {
    /// Whether anything shown so far was a notice (the hold-to-talk hint, or "I didn't catch that").
    var modesContainNotice: Bool {
        hud.modes.contains { if case .notice = $0 { true } else { false } }
    }
}
