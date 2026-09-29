import Foundation
import Testing
@testable import VoxaApp
import VoxaCore
import VoxaHUD
import VoxaTestSupport

@MainActor
@Suite("ConfirmationCoordinator")
struct ConfirmationCoordinatorTests {
    private let hud = FakeHUD()
    private let hotkeys = FakeHotkeyService()
    private let clock = ManualClock()
    private let coordinator: ConfirmationCoordinator

    private let prompt = ConfirmationPrompt(
        toolName: "run_applescript",
        title: "Run an AppleScript",
        summary: "Runs a script.",
        details: [DetailRow("Script", "return 1", style: .code)],
        risk: .sensitive,
        reasons: ["AppleScript can control other apps."]
    )

    init() {
        coordinator = ConfirmationCoordinator(hud: hud, hotkeys: hotkeys, clock: clock)
    }

    /// Starts a prompt and waits until it is on screen.
    private func ask(_ prompt: ConfirmationPrompt? = nil) async -> Task<ConfirmationOutcome, Never> {
        let coordinator = coordinator
        let prompt = prompt ?? self.prompt
        let task = Task { await coordinator.confirm(prompt) }
        _ = await waitUntil { coordinator.isAwaitingAnswer }
        return task
    }

    private func passGuard() async {
        _ = await clock.waitForSleepers(atLeast: 2)  // the input guard and the timeout
        clock.advance(by: ConfirmationCoordinator.inputGuard)
        _ = await waitUntil { hud.keysEnabled }
    }

    @Test("the prompt appears with the keyboard off, and the card shows exactly what was passed")
    func appears() async {
        let task = await ask()
        #expect(hud.modes == [.confirm(prompt)])
        #expect(!hud.keysEnabled)
        #expect(coordinator.isAwaitingAnswer)
        #expect(hotkeys.activeAllowListeners == 0, "the chord isn't captured while the guard runs")
        task.cancel()
        _ = await task.value
    }

    @Test("after the input guard, ⌘Return works and approves")
    func returnApproves() async {
        let task = await ask()
        await passGuard()
        #expect(hud.keysEnabled)
        #expect(await waitUntil { hotkeys.activeAllowListeners == 1 })

        hotkeys.pressAllow()
        #expect(await task.value == .approved)
        #expect(!coordinator.isAwaitingAnswer)
        #expect(hud.lastMode == .acting(title: "Run an AppleScript"), "the card gives way to progress")
        #expect(
            await waitUntil { hotkeys.activeAllowListeners == 0 },
            "the chord is released as soon as the prompt is answered"
        )
        #expect(!hud.keysEnabled)
    }

    @Test("⌘Return pressed during the guard does nothing, because it isn't even registered")
    func returnDuringGuard() async {
        let task = await ask()
        hotkeys.pressAllow()
        await settle()
        #expect(coordinator.isAwaitingAnswer)
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test("the Allow button is ignored during the guard and works after it")
    func allowButton() async {
        let task = await ask()
        hud.onConfirmationChoice?(.allow)
        await settle()
        #expect(coordinator.isAwaitingAnswer, "too early")

        await passGuard()
        hud.onConfirmationChoice?(.allow)
        #expect(await task.value == .approved)
    }

    @Test("declining works at once, even during the guard")
    func decline() async {
        let task = await ask()
        hud.onConfirmationChoice?(.deny)
        #expect(await task.value == .denied)
        #expect(hud.lastMode == .thinking(partial: nil))
    }

    @Test("an unanswered prompt ends as a refusal after its timeout")
    func timeout() async {
        let task = await ask()
        _ = await clock.waitForSleepers(atLeast: 2)
        clock.advance(by: .seconds(61))
        #expect(await task.value == .timedOut)
        #expect(!coordinator.isAwaitingAnswer)
    }

    @Test("cancelling the command ends the prompt, and the card is left for whoever cancelled")
    func cancellation() async {
        let task = await ask()
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(!coordinator.isAwaitingAnswer)
        #expect(hud.modes == [.confirm(prompt)], "no progress card is drawn for a cancelled command")
    }

    @Test("a command that is already cancelled never shows a prompt")
    func alreadyCancelled() async {
        let coordinator = coordinator
        let prompt = prompt
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.confirm(prompt)
        }
        #expect(await task.value == .cancelled)
        #expect(hud.modes.isEmpty)
    }

    @Test("a second prompt while one is up is declined, and the first is unaffected")
    func onlyOneAtATime() async {
        let first = await ask()
        let second = await coordinator.confirm(
            ConfirmationPrompt(toolName: "x", title: "Other", summary: "", risk: .sensitive)
        )
        #expect(second == .denied)
        #expect(coordinator.isAwaitingAnswer)
        first.cancel()
        _ = await first.value
    }

    // MARK: Voice

    @Test("a spoken yes approves and a spoken no declines")
    func voice() async {
        let yes = await ask()
        coordinator.submitSpokenAnswer("Yes, go ahead.")
        #expect(await yes.value == .approved)

        let no = await ask()
        coordinator.submitSpokenAnswer("no")
        #expect(await no.value == .denied)
    }

    @Test(
        "anything that isn't a clear yes or no leaves the prompt up and says so",
        arguments: [
            "yes but also delete everything", "maybe", "open safari", "yes no", "hmm",
        ]
    )
    func voiceUnclear(text: String) async {
        let task = await ask()
        coordinator.submitSpokenAnswer(text)
        await settle()
        #expect(coordinator.isAwaitingAnswer)
        #expect(hud.lastAnswerStatus == .unclear)
        task.cancel()
        _ = await task.value
    }

    @Test("a spoken answer with nothing pending does nothing")
    func voiceWithoutPrompt() {
        coordinator.submitSpokenAnswer("yes")
        #expect(hud.modes.isEmpty)
    }

    @Test("late or repeated answers after the prompt is settled do nothing")
    func answeredOnce() async {
        let task = await ask()
        await passGuard()
        hotkeys.pressAllow()
        #expect(await task.value == .approved)

        // Everything below arrives after the prompt is gone. A second resume of the continuation would crash the test.
        hotkeys.pressAllow()
        hud.onConfirmationChoice?(.deny)
        coordinator.submitSpokenAnswer("no")
        await settle()
        #expect(!coordinator.isAwaitingAnswer)
        #expect(hud.modes.last == .acting(title: "Run an AppleScript"))
    }
}
