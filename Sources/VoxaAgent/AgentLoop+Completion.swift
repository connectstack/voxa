import Foundation
import VoxaCore
import VoxaLLM

/// Checking that a command is really finished before its reply is accepted.
///
/// Models tend to stop at the first step that looks like an answer: "Play X on YouTube" ends at "I opened the search results".
/// When the model stops and the run used a tool that may be only a step (opening a page, clicking), the reply goes to a checker
/// first. If the checker finds something plainly still left, the model is sent back to it with a note; otherwise the reply
/// stands. The check can only ever *add* work that the user's own command asked for, it never ends a command early, and when it
/// can't be made the reply stands.
extension AgentLoop {
    /// The most times one command is sent back to work. Two covers "open it, then play it"; more would mean the checker and the
    /// model disagree about a command, and the user is better served by the answer they have.
    static let maxChecks = 2

    /// Time that must remain after a check for the model to act on it, or the check isn't worth making.
    static let timeToActOnACheck: Duration = .seconds(15)

    /// The model has stopped and wants to reply. Returns the result if the reply stands, or nil when the check found the command
    /// unfinished and the model has been sent back to work (the caller carries on with the next step).
    func concludeOrContinue(_ run: Run, _ response: LLMResponse) async throws -> AgentRunResult? {
        guard let missing = try await stillLeft(run, response) else { return finishWithText(run, response) }
        let reply = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        run.messages.append(LLMMessage(role: .assistant, content: Self.closingContent(response, reply: reply)))
        run.messages.append(.user(Self.note(missing: missing)))
        return nil
    }

    /// What the checker says is still left, or nil when the reply should stand.
    private func stillLeft(_ run: Run, _ response: LLMResponse) async throws -> String? {
        guard let verifier, run.configuration.verifyCompletion else { return nil }
        // Only when the model can still act on it: a step left, time left, the user not having said no to something on the way.
        guard run.checks < Self.maxChecks, run.steps < run.configuration.maxSteps, run.declines == 0 else { return nil }
        // Only when a tool ran that may be only a step: an event that was added, or a question answered, needs no second look.
        guard run.trace.contains(where: \.mayLeaveTaskUnfinished) else { return nil }
        let reply = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, !Self.asksSomething(reply) else { return nil }
        guard await run.deadline.remaining() >= limits.checkTimeout + Self.timeToActOnACheck else { return nil }

        run.checks += 1
        // The reply the model has been streaming is not final until the check says so.
        run.emit(.thinking(step: run.steps))
        let evidence = CompletionEvidence(
            command: run.command,
            actions: run.trace.map { CompletionEvidence.Action(title: $0.title, succeeded: $0.succeeded) },
            reply: reply
        )
        let configuration = run.configuration
        let verdict: CompletionVerdict?
        do {
            verdict = try await withTimeout(limits.checkTimeout, clock: clock) {
                await verifier.verdict(for: evidence, configuration: configuration)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            verdict = nil
        }
        // Esc pressed while the checker was thinking ends the command, not lets the reply through.
        try Task.checkCancellation()

        guard let verdict else {
            await record(run, .completionCheck, outcome: "unavailable")
            return nil
        }
        // "unsure" is a not-finished answer too weak to act on: the reply stands, but the trail doesn't call it a yes.
        await record(
            run,
            .completionCheck,
            outcome: verdict.isDone ? "done" : (verdict.shouldContinue ? "notDone" : "unsure"),
            detail: verdict.shouldContinue ? verdict.missing : nil
        )
        return verdict.shouldContinue ? verdict.missing : nil
    }

    /// A reply that asks the user something is waiting for them, not for a tool.
    static func asksSomething(_ reply: String) -> Bool {
        let closing = reply.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’)")))
        return closing.hasSuffix("?") || closing.hasSuffix("？")
    }

    /// Voxa's own note to the model, in the user's turn (never inside a tool result). It asks for the user's command to be
    /// finished and for nothing else, and gives the way out: say so if it is done or can't be.
    static func note(missing: String) -> String {
        "Check: this command isn't finished yet, because \(missing). Carry on with what the user asked, using your tools, and "
            + "do nothing else. If it is already done, or can't be done, say so plainly in your reply."
    }
}
