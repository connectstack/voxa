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

    /// Lets the "not an accidental tap" hold time pass.
    func holdLongEnough() async {
        clock.advance(by: .milliseconds(300))
        await settle()
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
