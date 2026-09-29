import Foundation
import VoxaAgent
import VoxaCore
import VoxaHUD

/// Driving the agent from the session: start it once a command is recognized, follow its progress on the HUD, and present
/// its reply (or its failure). Esc stops it at any point.
extension VoiceSessionController {
    func startAgent(_ agent: any AgentRunning, command: String) {
        let token = UUID()
        agentToken = token
        agentStage = .thinking
        hud.show(.thinking(partial: nil))

        // Esc stops the command from here until its reply is on screen.
        let presses = hotkeys.cancelKeyPresses()
        agentCancelWatcher = Task { [weak self] in
            for await _ in presses {
                self?.cancel()
                return
            }
        }

        // Events reach the main actor in the order the agent produced them.
        let (events, continuation) = AsyncStream<AgentEvent>.makeStream()
        let consumer = Task { [weak self] in
            for await event in events {
                self?.handle(event, token: token)
            }
        }
        let now = now
        agentTask = Task { [weak self] in
            let result = await agent.run(command, now: now(), onEvent: { continuation.yield($0) })
            continuation.finish()
            await consumer.value
            self?.agentFinished(result, token: token)
        }
    }

    private func handle(_ event: AgentEvent, token: UUID) {
        guard agentToken == token else { return }
        // While a question is on screen, progress events must not draw over it.
        let asking = confirmations?.isAwaitingAnswer == true
        switch event {
        case .thinking:
            agentStage = .thinking
            if !asking { hud.show(.thinking(partial: nil)) }
        case .replyText(let text):
            if !asking, agentStage == .thinking { hud.show(.thinking(partial: text)) }
        case .acting(let title):
            agentStage = .acting
            if !asking { hud.show(.acting(title: title)) }
        case .finishedTool, .awaitingConfirmation, .retrying:
            break
        }
    }

    private func agentFinished(_ result: AgentRunResult, token: UUID) {
        guard agentToken == token else { return }
        let watcher = agentCancelWatcher
        agentTask = nil
        agentToken = nil
        agentStage = nil
        agentCancelWatcher = nil
        Log.session.info("command finished: \(result.outcome.auditWord, privacy: .public), \(result.steps) step(s)")

        switch result.outcome {
        case .cancelled:
            watcher?.cancel()
            hud.hide(after: nil)
        case .failed(let error):
            watcher?.cancel()
            presentFailure(error)
        case .completed, .limitReached, .timedOut, .refused, .stoppedAfterDeclines:
            let duration = replyDuration(for: result.reply)
            hud.show(.reply(result.reply))
            speaker?.speakReply(result.reply)
            hud.hide(after: duration)
            armDismiss(for: duration, keeping: watcher)
        }
    }

    /// Esc: stop the agent, and any spoken answer being recorded for it, and clear the screen.
    func cancelAgent() {
        agentTask?.cancel()
        agentCancelWatcher?.cancel()
        agentTask = nil
        agentToken = nil
        agentStage = nil
        agentCancelWatcher = nil
        if let run, !run.isFinished {
            run.isCancelled = true
            run.task?.cancel()
            finish(run)
        }
        phase = .idle
        hud.hide(after: nil)
    }

    private func replyDuration(for reply: String) -> Duration {
        let words = reply.split(whereSeparator: \.isWhitespace).count
        return min(configuration.replyMaximum, configuration.replyBase + configuration.replyPerWord * words)
    }
}

#if DEBUG
extension VoiceSessionController {
    /// Runs a command as if the microphone had recognized it. Lets a shell drive the agent without speaking. Debug builds only.
    public func debugSubmit(_ text: String) {
        guard agentTask == nil, run == nil || run?.isFinished == true, let agent else { return }
        errorResetTask?.cancel()
        disarmDismiss()
        lastError = nil
        hud.hotkeyHint = hotkeys.pushToTalkDescription
        hud.beginSession()
        hud.setTranscript(text, isFinal: true)
        startAgent(agent, command: text)
    }
}
#endif
