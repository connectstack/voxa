import Foundation
import Observation
import VoxaAgent
import VoxaCore
import VoxaHUD
import VoxaPolicy

/// What the session controller needs from the confirmation flow: whether a prompt is up, and a way to hand it a spoken
/// answer.
@MainActor
public protocol ConfirmationResponding: AnyObject {
    /// Whether a confirmation is on screen waiting for an answer.
    var isAwaitingAnswer: Bool { get }
    /// Passes on what the user said while a confirmation was up. A clear yes or no answers it; anything else leaves the
    /// prompt up and says so.
    func submitSpokenAnswer(_ transcript: String)
}

/// Asks the user to approve an action, three ways at once: the buttons, ⌘Return, or a spoken yes or no. Whichever comes
/// first decides, and the prompt can't be left dangling: it ends on its own after `prompt.timeout` (as a refusal), and
/// cancelling the command ends it at once.
///
/// Safety properties, each covered by a test:
/// - **Fail closed.** Silence, a timeout, a second prompt arriving while one is up, or any doubt means *no*.
/// - **Input guard.** For the first 400 ms neither ⌘Return nor the Allow button works, so a keystroke already on its way
///   when the prompt appears can't approve it. (Declining works immediately.) The chord isn't even registered as a global
///   shortcut until the guard has passed, so it isn't swallowed from other apps meanwhile.
/// - **The keyboard answer is a chord, not plain Return**, and is only captured while a prompt is up. A global shortcut
///   swallows what it matches; with plain Return, sending a message in another app would approve a pending action.
/// - **Only a whole, plain yes approves by voice** (see `VoiceAnswerParser`), and voice needs the push-to-talk hold, so
///   ambient audio can't approve anything.
@MainActor
@Observable
public final class ConfirmationCoordinator: ConfirmationProviding, ConfirmationResponding {
    public static let inputGuard: Duration = .milliseconds(400)

    public private(set) var isAwaitingAnswer = false

    @ObservationIgnored private let hud: any HUDPresenting
    @ObservationIgnored private let hotkeys: any HotkeyService
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var pending: Pending?

    public init(hud: any HUDPresenting, hotkeys: any HotkeyService, clock: any Clock<Duration> = ContinuousClock()) {
        self.hud = hud
        self.hotkeys = hotkeys
        self.clock = clock
    }

    // MARK: ConfirmationProviding

    public nonisolated func confirm(_ prompt: ConfirmationPrompt) async -> ConfirmationOutcome {
        await present(prompt)
    }

    private func present(_ prompt: ConfirmationPrompt) async -> ConfirmationOutcome {
        if Task.isCancelled { return .cancelled }
        // One prompt at a time. If this ever happened it would be a bug, and the safe answer to a bug is no.
        guard pending == nil else {
            Log.policy.error("a confirmation was requested while another was showing; declining it")
            return .denied
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                begin(Pending(prompt: prompt, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.cancelled) }
        }
    }

    // MARK: ConfirmationResponding

    public func submitSpokenAnswer(_ transcript: String) {
        guard pending != nil else { return }
        switch VoiceAnswerParser.parse(transcript) {
        case .yes: finish(.approved, via: "voice")
        case .no: finish(.denied, via: "voice")
        case .unclear: hud.setAnswerStatus(.unclear)
        }
    }

    // MARK: The prompt

    private func begin(_ pending: Pending) {
        self.pending = pending
        isAwaitingAnswer = true
        Log.policy.info("asking the user to confirm an action")

        hud.onConfirmationChoice = { [weak self] choice in self?.handle(choice, via: "button") }
        hud.setConfirmationKeysEnabled(false)
        hud.setAnswerStatus(.idle)
        hud.show(.confirm(pending.prompt))

        pending.guardTask = Task { [weak self, clock] in
            try? await clock.sleep(for: Self.inputGuard)
            guard !Task.isCancelled else { return }
            self?.armKeyboard(for: pending)
        }
        pending.timeoutTask = Task { [weak self, clock] in
            try? await clock.sleep(for: pending.prompt.timeout)
            guard !Task.isCancelled else { return }
            Log.policy.info("confirmation timed out; treating it as a refusal")
            self?.finish(.timedOut, ifCurrent: pending)
        }
    }

    /// The guard has passed: the Allow button and ⌘Return start working.
    private func armKeyboard(for pending: Pending) {
        guard self.pending === pending else { return }
        pending.isArmed = true
        hud.setConfirmationKeysEnabled(true)
        let presses = hotkeys.allowKeyPresses()
        pending.keyTask = Task { [weak self] in
            for await _ in presses {
                self?.handle(.allow, via: "key")
            }
        }
    }

    private func handle(_ choice: ConfirmationChoice, via method: String) {
        guard let pending else { return }
        switch choice {
        case .allow:
            // Ignored until the guard has passed; the button is disabled then too, but a press can still arrive.
            guard pending.isArmed else { return }
            finish(.approved, via: method)
        case .deny:
            finish(.denied, via: method)
        }
    }

    /// Ends the prompt exactly once, whichever way it was answered.
    private func finish(_ outcome: ConfirmationOutcome, via method: String = "system", ifCurrent expected: Pending? = nil) {
        guard let pending, expected == nil || expected === pending else { return }
        // Which way it was answered is worth knowing when something was approved that shouldn't have been. No content.
        Log.policy.notice("confirmation answered: \(outcome.auditWord, privacy: .public) via \(method, privacy: .public)")
        self.pending = nil
        isAwaitingAnswer = false
        pending.cancelTasks()

        hud.onConfirmationChoice = nil
        hud.setConfirmationKeysEnabled(false)
        hud.setAnswerStatus(.idle)
        // Show that the command carries on, so the card doesn't sit there after it has been answered. A cancelled command
        // is torn down by whoever cancelled it.
        switch outcome {
        case .approved: hud.show(.acting(title: pending.prompt.title))
        case .denied, .timedOut: hud.show(.thinking(partial: nil))
        case .cancelled: break
        }
        pending.continuation.resume(returning: outcome)
    }
}

@MainActor
private final class Pending {
    let prompt: ConfirmationPrompt
    let continuation: CheckedContinuation<ConfirmationOutcome, Never>
    var isArmed = false
    var guardTask: Task<Void, Never>?
    var keyTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    init(prompt: ConfirmationPrompt, continuation: CheckedContinuation<ConfirmationOutcome, Never>) {
        self.prompt = prompt
        self.continuation = continuation
    }

    func cancelTasks() {
        guardTask?.cancel()
        keyTask?.cancel()
        timeoutTask?.cancel()
    }
}
