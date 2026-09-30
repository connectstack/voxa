import Foundation
import Testing
@testable import VoxaApp
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaSpeech
import VoxaTestSupport

/// Counts how often the session asks which permissions it needs.
private final class CountingRecognizer: SpeechRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var queries = 0

    var permissionQueries: Int { lock.withLock { queries } }

    func requiredPermissions(locale: Locale) async -> Set<PermissionKind> {
        lock.withLock { queries += 1 }
        return []
    }

    func prepare(locale: Locale) async throws {}

    func transcribe(
        _ audio: AsyncThrowingStream<AudioChunk, any Error>,
        locale: Locale
    ) -> AsyncThrowingStream<Transcript, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
@Suite("VoiceSessionController")
struct VoiceSessionControllerTests {
    // MARK: Happy path

    @Test("hold, speak, release: live transcript, then the recognized command")
    func fullCommand() async {
        let h = SessionHarness()
        #expect(h.phase == .idle)

        #expect(await h.pressAndListen())
        #expect(h.hud.hotkeyHint == "⌥Space")
        #expect(h.hud.beginCount == 1)
        #expect(h.hud.modes.contains(.listening))

        await h.capture.emitChunk()
        await h.capture.emitChunk()
        #expect(await waitUntil { h.hud.events.contains(.transcript("open safari", isFinal: false)) })

        await h.holdLongEnough()
        await h.releaseAndFinishTail()
        #expect(await h.waitForMode(.result("Open Safari.")))

        #expect(h.phase == .idle)
        #expect(h.hud.events.contains(.transcript("Open Safari.", isFinal: true)))
        #expect(h.hud.modes.contains(.transcribing))
        #expect(await h.capture.stopCount >= 1)
        #expect(h.hud.events.contains(.hide(after: .seconds(3))))
    }

    @Test("the microphone keeps recording for a short tail after the key is released")
    func releaseTail() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        await h.holdLongEnough()

        h.hotkeys.release()
        _ = await waitUntil { h.clock.sleeperCount >= 2 }
        await settle()
        #expect(await h.capture.isCapturing, "still recording during the tail")
        #expect(h.phase == .listening)

        h.clock.advance(by: .milliseconds(250))
        #expect(await waitUntil { await !h.capture.isCapturing })
    }

    @Test("microphone levels are forwarded to the HUD")
    func levels() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        await h.capture.emit(level: AudioLevel(rms: 0.4, peak: 0.6))
        await h.capture.emit(level: AudioLevel(rms: 0.5, peak: 0.7))
        #expect(await waitUntil { h.hud.levelCount == 2 })
    }

    @Test("an empty transcript shows a friendly notice, not an error")
    func nothingHeard() async {
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(ending: .completes(final: "   ")))
        await h.speakAndRelease()
        #expect(await waitUntil { if case .notice = h.hud.lastMode { true } else { false } })

        guard case .notice(let title, let detail) = h.hud.lastMode else {
            Issue.record("expected a notice, got \(String(describing: h.hud.lastMode))")
            return
        }
        #expect(title == L10n.HUD.didntCatch)
        #expect(detail == L10n.HUD.didntCatchDetail("⌥Space"))
        #expect(h.phase == .idle)
    }

    // MARK: Accidental taps, cancellation, limits

    @Test("a quick tap says how push-to-talk works instead of vanishing")
    func accidentalTap() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        h.hotkeys.release()   // no time has passed on the clock

        #expect(await waitUntil { await h.capture.stopCount >= 1 })
        #expect(await waitUntil { h.holdHintIsShowing })
        #expect(h.phase == .idle)
        #expect(!h.hud.modes.contains { if case .result = $0 { true } else { false } })
        #expect(!h.hud.modes.contains { if case .error = $0 { true } else { false } })

        guard case .notice(_, let detail) = h.hud.lastMode else {
            Issue.record("expected the hold-to-talk hint")
            return
        }
        #expect(detail == L10n.HUD.holdToTalkDetail("⌥Space"))
        #expect(h.hud.events.contains(.hide(after: .milliseconds(2500))))
    }

    @Test("a tap released before the microphone finished opening gets the same hint")
    func tapDuringStartup() async {
        let h = SessionHarness()
        h.hotkeys.press()
        h.hotkeys.release()
        #expect(await waitUntil { h.holdHintIsShowing })
        #expect(await waitUntil { await h.capture.stopCount >= 1 })
        #expect(h.phase == .idle)
        #expect(!h.hud.modes.contains(.listening), "no Listening flash for a tap")
    }

    @Test("a tap is answered at once, without waiting for a slow permission prompt or microphone")
    func tapIsImmediate() async {
        let h = SessionHarness()
        let gate = AsyncGate()
        h.permissions.statuses[.microphone] = .notDetermined
        h.permissions.whileRequesting = { await gate.wait() }   // startup is stuck behind a "prompt"

        h.hotkeys.press()
        #expect(await waitUntil { h.permissions.requested == [.microphone] })
        h.hotkeys.release()   // still inside the minimum hold

        #expect(await waitUntil { h.holdHintIsShowing }, "the hint must not wait for the prompt to be answered")
        #expect(h.phase == .idle)
        await gate.open()
        await settle()
        #expect(await h.capture.startCount == 0, "a tap must never open the microphone")
    }

    @Test("Esc dismisses the tap hint like any other message")
    func escapeDismissesHint() async {
        let h = SessionHarness()
        h.hotkeys.press()
        h.hotkeys.release()
        #expect(await waitUntil { h.holdHintIsShowing })
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 1 })

        h.hotkeys.pressEscape()
        #expect(await waitUntil { h.hud.isDismissed })
    }

    @Test("a hold that outlasts the minimum is a real command, not a tap")
    func holdIsNotATap() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        await h.capture.emitChunk()
        await h.holdLongEnough()
        await h.releaseAndFinishTail()

        #expect(await h.waitForMode(.result("Open Safari.")))
        #expect(!h.holdHintIsShowing)
    }

    @Test("Esc cancels a listening session, stops the microphone and dismisses the HUD")
    func escapeCancels() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 1 })

        h.hotkeys.pressEscape()

        #expect(await h.waitForPhase(.idle))
        #expect(await waitUntil { await !h.capture.isCapturing })
        #expect(await waitUntil { h.hud.isDismissed })
        #expect(!h.hud.modes.contains { if case .result = $0 { true } else { false } })
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 0 })
    }

    @Test("Esc is only captured while a session needs it")
    func escapeIsScoped() async {
        let h = SessionHarness()
        #expect(h.hotkeys.activeCancelListeners == 0, "idle: Esc belongs to the frontmost app")

        await h.speakAndRelease()
        #expect(await h.waitForMode(.result("Open Safari.")))
        // While the result is on screen Esc dismisses it...
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 1 })

        // ...and once the HUD has gone, Esc is released again.
        #expect(await h.advanceClock(by: .seconds(3)) { h.hotkeys.activeCancelListeners == 0 })
    }

    @Test("Esc dismisses a result that is still showing")
    func escapeDismissesResult() async {
        let h = SessionHarness()
        await h.speakAndRelease()
        #expect(await h.waitForMode(.result("Open Safari.")))
        #expect(await waitUntil { h.hotkeys.activeCancelListeners == 1 })

        h.hotkeys.pressEscape()
        #expect(await waitUntil { h.hud.isDismissed })
    }

    @Test("the recording limit stops a session that is never released")
    func recordingLimit() async {
        let h = SessionHarness()
        h.settings.current.maxRecordingSeconds = 5
        _ = await h.pressAndListen()
        await h.capture.emitChunk()
        _ = await waitUntil { h.clock.sleeperCount >= 2 }   // min hold + limit

        h.clock.advance(by: .seconds(5))
        await settle()
        _ = await waitUntil { h.clock.sleeperCount >= 1 }
        h.clock.advance(by: .milliseconds(250))   // the release tail

        #expect(await h.waitForMode(.result("Open Safari.")))
    }

    @Test("a second press while a command is running is ignored")
    func doublePress() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        h.hotkeys.press()
        await settle()
        #expect(await h.capture.startCount == 1)
        #expect(h.hud.beginCount == 1)
    }

    @Test("a new press after a result starts a fresh command")
    func pressAfterResult() async {
        let h = SessionHarness()
        await h.speakAndRelease()
        #expect(await h.waitForMode(.result("Open Safari.")))

        _ = await h.pressAndListen()
        #expect(h.hud.beginCount == 2)
        #expect(await h.capture.startCount == 2)
    }

    // MARK: Watchdog

    @Test("if the recognizer never finishes, the latest partial transcript is used after the timeout")
    func finalizationWatchdog() async {
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(partials: ["hello world"], ending: .neverFinishes))
        _ = await h.pressAndListen()
        await h.capture.emitChunk()
        #expect(await waitUntil { h.hud.events.contains(.transcript("hello world", isFinal: false)) })
        await h.holdLongEnough()
        await h.releaseAndFinishTail()

        #expect(await h.waitForPhase(.finalizing))
        #expect(await waitUntil { h.clock.sleeperCount >= 2 })   // limit + finalization watchdog
        #expect(!h.hud.modes.contains(.result("hello world")), "must not finish before the timeout")

        h.clock.advance(by: .seconds(5))
        #expect(await h.waitForMode(.result("hello world")))
        #expect(h.phase == .idle)
    }

    // MARK: Permissions

    @Test("a denied microphone shows a fix-it error and never opens the microphone")
    func microphoneDenied() async {
        let h = SessionHarness()
        h.permissions.statuses[.microphone] = .denied

        h.hotkeys.press()
        #expect(await h.waitForPhase(.failed))

        let expected = UserFacingError.permissionRequired(.microphone, status: .denied)
        #expect(h.hud.lastMode == .error(expected))
        #expect(await h.capture.startCount == 0)
        #expect(h.controller.lastError == expected)
        #expect(h.controller.status == .error)
    }

    @Test("the error's button opens System Settings at the right pane and dismisses the HUD")
    func recoveryButton() async {
        let h = SessionHarness()
        h.permissions.statuses[.microphone] = .denied
        h.hotkeys.press()
        #expect(await h.waitForPhase(.failed))

        h.hud.onRecovery?(.openSystemSettings(.microphone))
        #expect(h.permissions.openedSettings == [.microphone])
        #expect(h.hud.isDismissed)
    }

    @Test("an app-settings recovery opens Voxa's settings window")
    func appSettingsRecovery() async {
        var opened = 0
        let h = SessionHarness(openAppSettings: { opened += 1 })
        h.hud.onRecovery?(.openAppSettings)
        #expect(opened == 1)
    }

    @Test("a model-settings recovery opens the settings on the model tab, not the general one")
    func modelSettingsRecovery() async {
        var general = 0
        var model = 0
        let h = SessionHarness(openAppSettings: { general += 1 }, openModelSettings: { model += 1 })
        h.hud.onRecovery?(.openModelSettings)
        #expect(model == 1)
        #expect(general == 0)
    }

    @Test("the failed state clears itself after the error has been on screen")
    func errorResets() async {
        let h = SessionHarness()
        h.permissions.statuses[.microphone] = .denied
        h.hotkeys.press()
        #expect(await h.waitForPhase(.failed))
        #expect(await h.clock.waitForSleepers())

        h.clock.advance(by: .seconds(8))
        #expect(await h.waitForPhase(.idle))
        #expect(h.controller.status == .idle)
    }

    @Test("an undetermined permission is requested, then the command proceeds")
    func promptThenProceed() async {
        let h = SessionHarness()
        h.permissions.statuses[.microphone] = .notDetermined

        #expect(await h.pressAndListen())
        #expect(h.permissions.requested == [.microphone])
    }

    @Test("permissions the speech engine needs are requested too")
    func engineSpecificPermissions() async {
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(permissions: [.speechRecognition]))
        h.permissions.statuses[.speechRecognition] = .denied

        h.hotkeys.press()
        #expect(await h.waitForPhase(.failed))
        #expect(h.hud.lastMode == .error(.permissionRequired(.speechRecognition, status: .denied)))
        #expect(await h.capture.startCount == 0)
    }

    @Test("releasing the key while a permission prompt is showing says you're all set instead of doing nothing")
    func releasedDuringPrompt() async {
        let h = SessionHarness()
        let gate = AsyncGate()
        h.permissions.statuses[.microphone] = .notDetermined
        h.permissions.whileRequesting = { await gate.wait() }

        h.hotkeys.press()
        #expect(await waitUntil { h.permissions.requested == [.microphone] })
        await h.holdLongEnough()   // a real hold: the user kept the key down while the prompt appeared
        h.hotkeys.release()
        await settle()
        await gate.open()

        #expect(await waitUntil {
            if case .notice(let title, _) = h.hud.lastMode { title == L10n.HUD.allSet } else { false }
        })
        #expect(await h.capture.startCount == 0)
        #expect(h.phase == .idle)
    }

    // MARK: Failures

    @Test("no microphone gives a clear message")
    func noMicrophone() async {
        let h = SessionHarness()
        await h.capture.setStartError(AudioCaptureError.noInputDevice)

        h.hotkeys.press()
        #expect(await h.waitForPhase(.failed))
        guard case .error(let error) = h.hud.lastMode else {
            Issue.record("expected an error")
            return
        }
        #expect(error.title == L10n.Errors.noInputDeviceTitle)
    }

    @Test("a microphone that disappears mid-command is reported")
    func deviceLost() async {
        let h = SessionHarness()
        _ = await h.pressAndListen()
        await h.capture.fail(with: AudioCaptureError.deviceLost)

        #expect(await h.waitForPhase(.failed))
        guard case .error(let error) = h.hud.lastMode else {
            Issue.record("expected an error")
            return
        }
        #expect(error.title == L10n.Errors.micLostTitle)
        #expect(await waitUntil { await h.capture.stopCount >= 1 })
    }

    @Test("a recognizer failure is reported and the microphone is released")
    func recognizerFails() async {
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(ending: .fails(SpeechError.recognizerUnavailable)))
        await h.speakAndRelease()

        #expect(await h.waitForPhase(.failed))
        #expect(h.hud.lastMode == .error(SpeechError.recognizerUnavailable.userFacing))
        #expect(await h.capture.stopCount >= 1)
    }

    @Test("an unknown error is translated instead of leaked")
    func unknownError() async {
        struct Mystery: Error {}
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(ending: .fails(Mystery())))
        await h.speakAndRelease()

        #expect(await h.waitForPhase(.failed))
        guard case .error(let error) = h.hud.lastMode else {
            Issue.record("expected an error")
            return
        }
        #expect(error.title == L10n.Errors.genericTitle)
    }

    // MARK: Status

    @Test("the menu-bar status tracks the session phase")
    func statusTracksPhase() async {
        let h = SessionHarness(recognizer: ScriptedSpeechRecognizer(partials: ["a"], ending: .neverFinishes))
        #expect(h.controller.status == .idle)

        _ = await h.pressAndListen()
        #expect(h.controller.status == .listening)

        await h.capture.emitChunk()
        await h.holdLongEnough()
        await h.releaseAndFinishTail()
        #expect(await h.waitForPhase(.finalizing))
        #expect(h.controller.status == .thinking)
    }
}

@MainActor
@Suite("VoiceSessionController: prewarming")
struct VoiceSessionPrewarmTests {
    @Test("prewarming asks the speech engine what it needs, once, without starting a command")
    func prewarm() async {
        let recognizer = CountingRecognizer()
        let h = SessionHarness(recognizer: recognizer)
        await h.controller.prewarm()

        #expect(recognizer.permissionQueries == 1)
        #expect(h.phase == .idle)
        #expect(await h.capture.startCount == 0)
        #expect(h.hud.events.isEmpty)
    }
}
