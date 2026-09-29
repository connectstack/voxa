import Foundation
import os
import Testing
import VoxaAgent
@testable import VoxaApp
import VoxaCore
import VoxaHUD
import VoxaSpeech
import VoxaTestSupport

/// An agent the test controls: it records commands, can emit events, and holds until released or cancelled.
final class FakeAgent: AgentRunning, @unchecked Sendable {
    struct Script: Sendable {
        var events: [AgentEvent] = []
        var result = AgentRunResult(outcome: .completed, reply: "Opened Safari.")
        /// Wait for `release()` (or cancellation) after emitting the events.
        var holds = false
    }

    private struct State {
        var commands: [String] = []
        var nows: [Date] = []
        var wasCancelled = false
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var emit: (@Sendable (AgentEvent) -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var script: Script

    init(_ script: Script = Script()) {
        self.script = script
    }

    var commands: [String] { state.withLock { $0.commands } }
    var wasCancelled: Bool { state.withLock { $0.wasCancelled } }
    var nows: [Date] { state.withLock { $0.nows } }

    /// Sends an event as if the agent produced it, while a command is running.
    func emit(_ event: AgentEvent) {
        state.withLock { $0.emit }?(event)
    }

    func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func run(_ command: String, now: Date, onEvent: AgentEventHandler?) async -> AgentRunResult {
        state.withLock {
            $0.commands.append(command)
            $0.nows.append(now)
            $0.emit = onEvent
        }
        for event in script.events { onEvent?(event) }
        guard script.holds else { return script.result }

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    if state.released { return true }
                    state.waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.wasCancelled = true }
            release()
        }
        return Task.isCancelled ? AgentRunResult(outcome: .cancelled, reply: "") : script.result
    }
}

@MainActor
final class FakeConfirmations: ConfirmationResponding {
    var isAwaitingAnswer = false
    private(set) var answers: [String] = []

    func submitSpokenAnswer(_ transcript: String) {
        answers.append(transcript)
    }
}

@MainActor
@Suite("VoiceSessionController with the agent")
struct AgentSessionTests {
    private func harness(
        _ script: FakeAgent.Script = FakeAgent.Script(),
        confirmations: FakeConfirmations? = nil
    ) -> (SessionHarness, FakeAgent) {
        let agent = FakeAgent(script)
        return (SessionHarness(agent: agent, confirmations: confirmations), agent)
    }

    private func reachAgent(_ harness: SessionHarness) async {
        await harness.speakAndRelease()
        _ = await waitUntil { harness.controller.agentStage != nil || harness.hud.lastMode != .transcribing }
    }

    // MARK: A normal command

    @Test("the recognized command goes to the agent, the HUD follows it, and the reply is shown")
    func fullCommand() async {
        let events: [AgentEvent] = [
            .thinking(step: 1), .replyText("Opening Safari"), .acting(title: "Open Safari"),
            .finishedTool(title: "Open Safari", succeeded: true, notice: "Opened Safari"), .thinking(step: 2),
        ]
        let (harness, agent) = harness(.init(events: events))
        await reachAgent(harness)

        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
        #expect(agent.commands == ["Open Safari."])
        #expect(agent.nows == [Date(timeIntervalSince1970: 1_800_000_000)])

        let modes = harness.hud.modes
        let thinkingIndex = modes.firstIndex(of: .thinking(partial: nil))
        let partialIndex = modes.firstIndex(of: .thinking(partial: "Opening Safari"))
        let actingIndex = modes.firstIndex(of: .acting(title: "Open Safari"))
        let replyIndex = modes.firstIndex(of: .reply("Opened Safari."))
        #expect(thinkingIndex != nil && partialIndex != nil && actingIndex != nil && replyIndex != nil)
        if let partialIndex, let actingIndex, let replyIndex {
            #expect(partialIndex < actingIndex && actingIndex < replyIndex)
        }
        #expect(harness.controller.agentStage == nil)
        #expect(harness.controller.status == .idle)
        #expect(!harness.hud.modes.contains(.result("Open Safari.")), "the plain transcript card is only for a session with no agent")
    }

    @Test("the menu-bar status follows the agent")
    func status() async {
        var script = FakeAgent.Script(events: [.thinking(step: 1)])
        script.holds = true
        let (harness, agent) = harness(script)
        await reachAgent(harness)

        #expect(await waitUntil { agent.commands.count == 1 }, "an event is only heard once the agent has started")
        #expect(await waitUntil { harness.controller.status == .thinking })
        agent.emit(.acting(title: "Open Safari"))
        #expect(await waitUntil { harness.controller.status == .acting })
        agent.release()
        #expect(await waitUntil { harness.controller.status == .idle })
    }

    @Test("a longer reply stays up longer, within limits")
    func replyDuration() async {
        for (reply, expected) in [
            ("Done.", Duration.seconds(4) + .milliseconds(350)),
            (String(repeating: "word ", count: 10), .seconds(4) + .milliseconds(3_500)),
            (String(repeating: "word ", count: 500), .seconds(20)),
        ] {
            let (harness, _) = harness(.init(result: AgentRunResult(outcome: .completed, reply: reply)))
            await reachAgent(harness)
            #expect(await waitUntil { harness.hud.lastMode == .reply(reply) })
            #expect(harness.hud.events.contains(.hide(after: expected)), "reply of \(reply.count) characters")
        }
    }

    @Test("Esc dismisses the reply, using the same Esc listener the command had")
    func escapeDismissesReply() async {
        let (harness, _) = harness()
        await reachAgent(harness)
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
        #expect(harness.hotkeys.activeCancelListeners == 1)

        harness.hotkeys.pressEscape()
        #expect(await waitUntil { harness.hud.isDismissed })
        #expect(await waitUntil { harness.hotkeys.activeCancelListeners == 0 })
    }

    @Test("Esc is captured only while a command is running or its reply is up")
    func escapeScope() async {
        let (harness, _) = harness()
        #expect(harness.hotkeys.activeCancelListeners == 0)
        await reachAgent(harness)
        _ = await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") }
        let released = await harness.advanceClock(by: .seconds(30)) { harness.hotkeys.activeCancelListeners == 0 }
        #expect(released, "after the reply times out, Esc goes back to other apps")
    }

    // MARK: Speaking

    @Test("the reply is spoken as well as shown")
    func replyIsSpoken() async {
        let (harness, _) = harness(.init(result: AgentRunResult(outcome: .completed, reply: "Opened Safari.")))
        await reachAgent(harness)
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
        #expect(harness.speaker.spoken.map(\.text) == ["Opened Safari."])
    }

    @Test("a failure is spoken as its title, and shown")
    func errorIsSpoken() async {
        let error = UserFacingError(title: "Ollama isn't running", detail: "Open the Ollama app, then try again.")
        let (harness, _) = harness(.init(result: AgentRunResult(outcome: .failed(error), reply: error.title)))
        await reachAgent(harness)
        #expect(await waitUntil { harness.hud.lastMode == .error(error) })
        #expect(harness.speaker.spoken.map(\.text) == ["Ollama isn't running"])
    }

    @Test("a cancelled command says nothing")
    func cancelledIsSilent() async {
        var script = FakeAgent.Script(events: [.thinking(step: 1)])
        script.holds = true
        let (harness, _) = harness(script)
        await reachAgent(harness)
        harness.hotkeys.pressEscape()
        #expect(await waitUntil { harness.controller.status == .idle })
        #expect(harness.speaker.spoken.isEmpty)
    }

    @Test("with spoken replies off the reply is only shown")
    func silentWhenOff() async {
        let (harness, _) = harness()
        harness.settings.current.speakReplies = false
        await reachAgent(harness)
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
        #expect(harness.speaker.spoken.isEmpty)
    }

    @Test("pressing the shortcut cuts the speech off before the microphone opens, so Voxa never hears itself")
    func pressStopsSpeech() async {
        let (harness, _) = harness()
        await reachAgent(harness)
        #expect(await waitUntil { harness.speaker.isSpeaking })
        let stopsBefore = harness.speaker.stopCount

        harness.hotkeys.press()
        #expect(await waitUntil { harness.speaker.stopCount > stopsBefore })
        #expect(!harness.speaker.isSpeaking)
    }

    @Test("Esc stops the speech too")
    func escapeStopsSpeech() async {
        let (harness, _) = harness()
        await reachAgent(harness)
        #expect(await waitUntil { harness.speaker.isSpeaking })
        harness.hotkeys.pressEscape()
        #expect(await waitUntil { !harness.speaker.isSpeaking })
    }

    // MARK: Cancelling

    @Test("Esc during the agent cancels it, hides the HUD, and shows no reply")
    func cancelWhileWorking() async {
        var script = FakeAgent.Script(events: [.thinking(step: 1)])
        script.holds = true
        let (harness, agent) = harness(script)
        await reachAgent(harness)
        #expect(await waitUntil { harness.controller.status == .thinking })

        harness.hotkeys.pressEscape()
        #expect(await waitUntil { agent.wasCancelled })
        #expect(await waitUntil { harness.controller.status == .idle })
        #expect(harness.hud.isDismissed)
        #expect(!harness.hud.modes.contains { if case .reply = $0 { true } else { false } })
    }

    @Test("a result that arrives after the command was cancelled is ignored")
    func lateResult() async {
        var script = FakeAgent.Script()
        script.holds = true
        let (harness, agent) = harness(script)
        await reachAgent(harness)
        _ = await waitUntil { agent.commands.count == 1 }

        harness.controller.cancel()
        agent.release()
        await settle()
        #expect(!harness.hud.modes.contains { if case .reply = $0 { true } else { false } })
        #expect(harness.controller.status == .idle)
    }

    // MARK: Presses while the agent works

    @Test("pressing the key while the agent is working does nothing")
    func pressIgnored() async {
        var script = FakeAgent.Script()
        script.holds = true
        let (harness, agent) = harness(script)
        await reachAgent(harness)
        _ = await waitUntil { agent.commands.count == 1 }
        let beginCount = harness.hud.beginCount

        harness.hotkeys.press()
        await settle()
        #expect(harness.hud.beginCount == beginCount)
        #expect(await !harness.capture.isCapturing)
        agent.release()
    }

    @Test("a new command can start as soon as the reply is up, and reaches the agent")
    func followUp() async {
        let (harness, agent) = harness()
        await reachAgent(harness)
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })

        await harness.speakAndRelease()
        #expect(await waitUntil { agent.commands.count == 2 })
    }

    // MARK: Answering a confirmation by voice

    @Test("a press during a confirmation records a spoken answer instead of starting a new command")
    func spokenAnswer() async {
        let confirmations = FakeConfirmations()
        var script = FakeAgent.Script()
        script.holds = true
        let recognizers = SequencedRecognizerProvider([
            ScriptedSpeechRecognizer(partials: ["open"], ending: .completes(final: "Open Safari.")),
            ScriptedSpeechRecognizer(partials: ["yes"], ending: .completes(final: "Yes.")),
        ])
        let agent = FakeAgent(script)
        let harness = SessionHarness(recognizers: recognizers, agent: agent, confirmations: confirmations)
        await harness.speakAndRelease()
        _ = await waitUntil { agent.commands.count == 1 }
        let beginCount = harness.hud.beginCount
        let modesBefore = harness.hud.modes

        confirmations.isAwaitingAnswer = true
        await harness.speakAndRelease()

        #expect(await waitUntil { confirmations.answers == ["Yes."] })
        #expect(harness.hud.beginCount == beginCount, "the confirmation card must not be reset")
        #expect(harness.hud.modes == modesBefore, "no listening or transcribing card is drawn over the question")
        #expect(harness.hud.events.contains(.answerStatus(.listening)))
        agent.release()
    }

    @Test("an answer that recorded nothing says it wasn't understood")
    func emptyAnswer() async {
        let confirmations = FakeConfirmations()
        var script = FakeAgent.Script()
        script.holds = true
        let recognizers = SequencedRecognizerProvider([
            ScriptedSpeechRecognizer(partials: ["open"], ending: .completes(final: "Open Safari.")),
            ScriptedSpeechRecognizer(partials: [], ending: .completes(final: "")),
        ])
        let agent = FakeAgent(script)
        let harness = SessionHarness(recognizers: recognizers, agent: agent, confirmations: confirmations)
        await harness.speakAndRelease()
        _ = await waitUntil { agent.commands.count == 1 }

        confirmations.isAwaitingAnswer = true
        await harness.speakAndRelease()
        #expect(await waitUntil { harness.hud.lastAnswerStatus == .unclear })
        #expect(confirmations.answers.isEmpty)
        agent.release()
    }

    @Test("a tap during a confirmation just resets the hint, with no error and no notice")
    func tapDuringConfirmation() async {
        let confirmations = FakeConfirmations()
        var script = FakeAgent.Script()
        script.holds = true
        let agent = FakeAgent(script)
        let harness = SessionHarness(agent: agent, confirmations: confirmations)
        await harness.speakAndRelease()
        _ = await waitUntil { agent.commands.count == 1 }
        let modesBefore = harness.hud.modes

        confirmations.isAwaitingAnswer = true
        harness.hotkeys.press()
        _ = await waitUntil { harness.controller.phase == .starting || harness.controller.phase == .listening }
        harness.hotkeys.release()
        #expect(await waitUntil { harness.controller.phase == .idle })
        #expect(harness.hud.modes == modesBefore)
        agent.release()
    }

    @Test("while a question is up the menu shows that Voxa is waiting for an answer")
    func statusConfirming() async {
        let confirmations = FakeConfirmations()
        var script = FakeAgent.Script(events: [.thinking(step: 1)])
        script.holds = true
        let agent = FakeAgent(script)
        let harness = SessionHarness(agent: agent, confirmations: confirmations)
        await harness.speakAndRelease()
        _ = await waitUntil { agent.commands.count == 1 }
        confirmations.isAwaitingAnswer = true
        #expect(harness.controller.status == .confirming)
        agent.release()
    }

    @Test("progress events don't draw over a question that is on screen")
    func progressDoesNotCoverQuestion() async {
        let confirmations = FakeConfirmations()
        var script = FakeAgent.Script()
        script.holds = true
        let agent = FakeAgent(script)
        let harness = SessionHarness(agent: agent, confirmations: confirmations)
        await harness.speakAndRelease()
        _ = await waitUntil { agent.commands.count == 1 }
        let before = harness.hud.modes.count

        confirmations.isAwaitingAnswer = true
        agent.emit(.thinking(step: 2))
        agent.emit(.acting(title: "Late"))
        await settle()
        #expect(harness.hud.modes.count == before)
        agent.release()
    }

    // MARK: Failures

    @Test("a failed command shows the error, remembers it for the menu, and recovers")
    func failure() async {
        let error = UserFacingError(title: "No API key", detail: "Add one in Settings.", recovery: .openAppSettings)
        let (harness, _) = harness(.init(result: AgentRunResult(outcome: .failed(error), reply: error.title)))
        await reachAgent(harness)

        #expect(await waitUntil { harness.hud.lastMode == .error(error) })
        #expect(harness.controller.lastError == error)
        #expect(harness.controller.status == .error)
        #expect(await harness.advanceClock(by: .seconds(8)) { harness.controller.status == .idle })
    }

    @Test("limits, refusals and timeouts are shown as replies")
    func otherOutcomes() async {
        for outcome: AgentRunResult.Outcome in [.limitReached(steps: 12), .timedOut, .refused, .stoppedAfterDeclines] {
            let (harness, _) = harness(.init(result: AgentRunResult(outcome: outcome, reply: "Reply for \(outcome.auditWord)")))
            await reachAgent(harness)
            #expect(await waitUntil { harness.hud.lastMode == .reply("Reply for \(outcome.auditWord)") })
        }
    }

    @Test("an agent that reports the command as cancelled leaves no card behind")
    func reportedCancelled() async {
        let (harness, _) = harness(.init(result: AgentRunResult(outcome: .cancelled, reply: "")))
        await reachAgent(harness)
        #expect(await waitUntil { harness.hud.isDismissed })
    }
}
