import Foundation
import Testing
@testable import VoxaApp
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaSpeech
import VoxaTestSupport

/// Everything a session test needs: the controller wired to fakes, plus helpers for the recurring choreography.
@MainActor
final class SessionHarness {
    let capture = FakeAudioCapture()
    let hud = FakeHUD()
    let hotkeys = FakeHotkeyService()
    let permissions = FakePermissions()
    let settings = FakeSettings()
    let clock = ManualClock()
    let speaker = FakeSpeaker()
    let controller: VoiceSessionController

    init(
        recognizer: any SpeechRecognizer = ScriptedSpeechRecognizer(
            partials: ["open", "open safari"],
            ending: .completes(final: "Open Safari.")
        ),
        configuration: VoiceSessionController.Configuration = .init(),
        openAppSettings: @escaping @MainActor () -> Void = {},
        openModelSettings: @escaping @MainActor () -> Void = {},
        recognizers: (any SpeechRecognizerProviding)? = nil,
        agent: (any AgentRunning)? = nil,
        confirmations: (any ConfirmationResponding)? = nil
    ) {
        controller = VoiceSessionController(
            capture: capture,
            recognizers: recognizers ?? FixedRecognizerProvider(recognizer),
            permissions: permissions,
            hud: hud,
            hotkeys: hotkeys,
            settings: settings,
            clock: clock,
            configuration: configuration,
            openAppSettings: openAppSettings,
            openModelSettings: openModelSettings,
            agent: agent,
            confirmations: confirmations,
            speaker: ReplySpeaker(synthesizer: speaker, settings: settings),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        controller.start()
    }

    var phase: VoiceSessionController.Phase { controller.phase }

    // MARK: Choreography

    /// Presses the key and waits until the microphone is open and the session is listening.
    @discardableResult
    func pressAndListen() async -> Bool {
        hotkeys.press()
        guard await waitUntil({ controller.phase == .listening }) else { return false }
        return await waitUntil { await capture.isCapturing }
    }

    /// Lets the "not an accidental tap" hold time pass, and waits until the controller has noticed that it has: its timer task sets
    /// the flag a moment after the clock moves, and a key released before that would count as a tap.
    func holdLongEnough() async {
        _ = await advanceClock(by: .milliseconds(300)) { controller.run?.minimumHoldElapsed == true }
    }

    /// Releases the key and lets the release tail elapse, which stops the microphone.
    func releaseAndFinishTail() async {
        hotkeys.release()
        // The tail timer is armed once the release is processed.
        _ = await waitUntil { clock.sleeperCount >= 2 }   // recording limit + tail
        clock.advance(by: .milliseconds(250))
        await settle()
    }

    /// A complete, normal utterance up to the point where the recognizer is finalizing.
    func speakAndRelease(chunks: Int = 2) async {
        _ = await pressAndListen()
        for _ in 0..<chunks {
            await capture.emitChunk()
        }
        await holdLongEnough()
        await releaseAndFinishTail()
    }

    /// Moves the clock on, and on again, until `condition` holds.
    ///
    /// The controller arms its timers from tasks of its own, which can run a moment after the screen shows what they belong to.
    /// One advance made in that moment passes over a timer that doesn't exist yet, and the wait after it would never end;
    /// moving on again each time round finds the timer once it does.
    func advanceClock(by step: Duration, until condition: @MainActor () -> Bool) async -> Bool {
        await waitUntil {
            clock.advance(by: step)
            return condition()
        }
    }

    /// Whether the most recent HUD state is the "hold the shortcut" hint shown after a tap.
    var holdHintIsShowing: Bool {
        if case .notice(let title, _) = hud.lastMode { title == L10n.HUD.holdToTalk } else { false }
    }

    func waitForMode(_ mode: HUDMode) async -> Bool {
        await waitUntil { hud.modes.contains(mode) }
    }

    func waitForPhase(_ phase: VoiceSessionController.Phase) async -> Bool {
        await waitUntil { controller.phase == phase }
    }
}
