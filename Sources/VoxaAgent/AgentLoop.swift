import Foundation
import os
import VoxaCore
import VoxaLLM
import VoxaPolicy

/// Runs one spoken command: asks the model, runs the tools it calls (through the policy and the user's confirmation),
/// feeds the results back, and repeats until the model answers, a limit is hit, or the user cancels.
///
/// Guarantees this type is responsible for (each has a test):
/// - **Nothing runs unless the policy allows it.** Every call goes through argument validation, the tool's own assessment
///   and `PolicyEngine`; a sensitive call waits for the user, whatever the model wrote.
/// - **Outside content stays data.** Tool output that isn't Voxa's own text is wrapped in the untrusted-data envelope, and
///   once it has entered the conversation the policy asks before further state-changing actions.
/// - **Bounded.** A step cap, a per-tool timeout, a total timeout that doesn't tick while the user decides, and a cap on
///   declines. Cancelling the task stops everything promptly.
/// - **Honest history.** The conversation only grows by whole, valid turns; a run that is cut short doesn't leave a tool
///   call without its result.
public struct AgentLoop: Sendable {
    let llm: any LLMClient
    let registry: ToolRegistry
    let confirmations: any ConfirmationProviding
    let permissions: any ToolPermissionGranting
    let audit: any AuditLogging
    let systemPrompt: SystemPrompt
    let clock: any Clock<Duration>
    let limits: AgentLimits

    public struct Output: Sendable {
        public var result: AgentRunResult
        /// The conversation to keep for a follow-up.
        public var memory: ConversationMemory
    }

    public init(
        llm: any LLMClient,
        registry: ToolRegistry,
        confirmations: any ConfirmationProviding,
        permissions: any ToolPermissionGranting = UnrestrictedToolPermissions(),
        audit: any AuditLogging = DiscardingAuditLog(),
        systemPrompt: SystemPrompt,
        clock: any Clock<Duration> = ContinuousClock(),
        limits: AgentLimits = AgentLimits()
    ) {
        self.llm = llm
        self.registry = registry
        self.confirmations = confirmations
        self.permissions = permissions
        self.audit = audit
        self.systemPrompt = systemPrompt
        self.clock = clock
        self.limits = limits
    }

    // MARK: Entry point

    public func run(
        command: String,
        memory: ConversationMemory,
        configuration: AgentRunConfiguration,
        context: RuntimeContext,
        onEvent: AgentEventHandler? = nil
    ) async -> Output {
        let run = Run(
            id: UUID(),
            command: command,
            base: memory,
            configuration: configuration,
            context: context,
            deadline: RunDeadline.start(clock: clock, limit: limits.totalTimeout),
            onEvent: onEvent
        )
        await record(run, .command, detail: command)
        run.messages = memory.messages + [.user(Self.userTurn(command: command, context: context))]
        run.taint = memory.taint

        let result: AgentRunResult
        do {
            result = try await withDeadline(run.deadline) { try await self.loop(run) }
        } catch is DeadlineExpired {
            result = finish(run, .timedOut, L10n.Agent.timedOut)
        } catch is CancellationError {
            result = finish(run, .cancelled, "")
        } catch where Task.isCancelled {
            result = finish(run, .cancelled, "")
        } catch {
            Log.agent.error("run failed: \(String(describing: error), privacy: .public)")
            let failure = UserFacingError.describing(error)
            result = finish(run, .failed(failure), failure.title)
        }

        await record(
            run,
            result.outcome == .completed ? .reply : .failure,
            outcome: result.outcome.auditWord,
            detail: result.reply
        )
        return Output(result: result, memory: run.committedMemory(for: result.outcome))
    }

    /// The user turn: Voxa's own facts, then what the user said.
    static func userTurn(command: String, context: RuntimeContext) -> String {
        context.render() + "\n\n" + command
    }

    // MARK: The loop

    private func loop(_ run: Run) async throws -> AgentRunResult {
        let tools = registry.definitions(excluding: run.configuration.disabledTools)
        let system = [SystemBlock(systemPrompt.render(maxSteps: run.configuration.maxSteps))]

        for step in 1...max(1, run.configuration.maxSteps) {
            try Task.checkCancellation()
            run.steps = step
            run.emit(.thinking(step: step))

            let request = LLMRequest(
                model: run.configuration.model,
                system: system,
                messages: run.messages,
                tools: tools,
                effort: run.configuration.effort,
                useRefusalFallback: run.configuration.useRefusalFallback,
                provider: run.configuration.provider,
                endpoint: run.configuration.endpoint,
                contextLength: run.configuration.contextLength
            )
            let streamed = StreamedText()
            let response = try await llm.complete(request) { event in
                switch event {
                case .blockDelta(_, .text(let delta)):
                    run.emit(.replyText(streamed.append(delta)))
                case .restarted:
                    streamed.reset()
                    run.emit(.retrying)
                default:
                    break
                }
            }
            run.usage.add(response.usage)

            switch response.stopReason {
            case .refusal:
                // The model declined. Whatever tool calls it had started are not executed and not kept.
                Log.agent.notice("the model declined the request")
                return finish(run, .refused, L10n.Agent.refused, assistantText: L10n.Agent.refused)

            case .maxTokens:
                // A tool call cut off mid-argument must never run.
                throw ProviderFailure(provider: run.configuration.provider, error: .incompleteStream)

            case .pauseTurn, .other:
                throw ProviderFailure(provider: run.configuration.provider, error: .invalidResponse("unexpected stop reason"))

            case .toolUse:
                let calls = response.executableToolUses
                guard !calls.isEmpty else { return finishWithText(run, response) }

                run.messages.append(LLMMessage(role: .assistant, content: response.contentForHistory))
                let batch = try await runCalls(calls, malformed: response.malformedToolInputs, run: run)
                // A tool needs a permission the user has refused: there is no point going on, and the error carries the
                // button that fixes it, which a model's sentence can't. What already ran stays in the conversation's note.
                if let missing = batch.missingPermission { throw missing }
                run.messages.append(LLMMessage(role: .user, content: batch.results))

                if batch.stopBecauseOfDeclines {
                    return finish(
                        run,
                        .stoppedAfterDeclines,
                        L10n.Agent.declinedStop,
                        assistantText: L10n.Agent.declinedStop
                    )
                }

            case .endTurn, .stopSequence, nil:
                return finishWithText(run, response)
            }
        }

        let reply = L10n.Agent.limitReached(run.configuration.maxSteps)
        return finish(run, .limitReached(steps: run.configuration.maxSteps), reply, assistantText: reply)
    }

    private func finishWithText(_ run: Run, _ response: LLMResponse) -> AgentRunResult {
        var reply = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty { reply = run.actions.isEmpty ? L10n.Agent.noReply : L10n.Agent.done }

        // This turn is final, so any tool call in it will never be answered, and a history that holds a call without its
        // result is rejected by the API on the next command. Keep the words and the reasoning, drop the calls.
        var content = response.contentForHistory.filter { block in
            if case .toolUse = block { false } else { true }
        }
        if content.isEmpty { content = [.text(reply)] }
        run.messages.append(LLMMessage(role: .assistant, content: content))
        return finish(run, .completed, reply)
    }

    /// Builds the result. `assistantText` closes the history with a plain assistant turn where the model didn't write one.
    func finish(
        _ run: Run,
        _ outcome: AgentRunResult.Outcome,
        _ reply: String,
        assistantText: String? = nil
    ) -> AgentRunResult {
        if let assistantText { run.messages.append(LLMMessage(role: .assistant, content: [.text(assistantText)])) }
        return AgentRunResult(outcome: outcome, reply: reply, steps: run.steps, actions: run.actions, usage: run.usage)
    }

    // MARK: Total timeout

    struct DeadlineExpired: Error {}

    private enum Race<T: Sendable>: Sendable {
        case finished(T)
        case expired
        case stopped
    }

    /// Runs `body`, giving up when the run's time budget is spent.
    private func withDeadline<T: Sendable>(
        _ deadline: RunDeadline,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Race<T>.self) { group in
            group.addTask { .finished(try await body()) }
            group.addTask {
                do {
                    try await deadline.waitUntilExpired()
                    return .expired
                } catch {
                    return .stopped
                }
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                switch next {
                case .finished(let value): return value
                case .expired: throw DeadlineExpired()
                case .stopped: continue
                }
            }
            throw CancellationError()
        }
    }
}
