import Foundation
import os
import VoxaCore
import VoxaLLM
import VoxaPolicy

// MARK: - Run state

/// Everything one command accumulates. A class because the loop's steps and the streaming callback share it; it is only
/// ever mutated by the single task running the loop, and read after that task has finished.
final class Run: @unchecked Sendable {
    let id: UUID
    let command: String
    let base: ConversationMemory
    let configuration: AgentRunConfiguration
    let context: RuntimeContext
    let deadline: RunDeadline
    private let onEvent: AgentEventHandler?

    var messages: [LLMMessage] = []
    var taint = RunTaint()
    var steps = 0
    var usage = Usage()
    var actions: [String] = []
    var declines = 0
    var declined: Set<String> = []

    /// One tool call that ran: what it was called, whether it worked, and whether it may have been only a step. The check reads
    /// this, not what the tools returned.
    struct Step {
        var title: String
        var succeeded: Bool
        var mayLeaveTaskUnfinished: Bool
    }

    var trace: [Step] = []
    /// How many times the completion check has been asked for this command (whatever it answered).
    var checks = 0

    init(
        id: UUID,
        command: String,
        base: ConversationMemory,
        configuration: AgentRunConfiguration,
        context: RuntimeContext,
        deadline: RunDeadline,
        onEvent: AgentEventHandler?
    ) {
        self.id = id
        self.command = command
        self.base = base
        self.configuration = configuration
        self.context = context
        self.deadline = deadline
        self.onEvent = onEvent
    }

    func emit(_ event: AgentEvent) {
        onEvent?(event)
    }

    /// What the model was shown in a picture (a screenshot of the user's window) stays with the command that asked for it. Kept
    /// for a follow-up, it would be sent to the model again, at the cost of thousands of tokens each time, and would hold
    /// whatever was on the screen for as long as the conversation lives. What the model *said* about it is kept.
    static let pictureRemoved = "[A picture was shown here. Pictures aren't kept once the command that took them has ended.]"

    static func withoutPictures(_ messages: [LLMMessage]) -> [LLMMessage] {
        messages.map { message in
            LLMMessage(
                role: message.role,
                content: message.content.map { block in
                    guard case .toolResult(let id, let parts, let isError) = block,
                        parts.contains(where: { if case .image = $0 { true } else { false } })
                    else { return block }
                    var kept: [ToolResultBlock] = []
                    for part in parts {
                        switch part {
                        case .image: if kept.last != .text(pictureRemoved) { kept.append(.text(pictureRemoved)) }
                        case .text: kept.append(part)
                        }
                    }
                    return .toolResult(toolUseID: id, content: kept, isError: isError)
                }
            )
        }
    }

    /// What to remember. A finished command keeps its whole conversation. One that was cut short keeps only a plain note
    /// of what already happened, because its history may end in a tool call that has no result, which the API rejects.
    func committedMemory(for outcome: AgentRunResult.Outcome) -> ConversationMemory {
        var memory = base
        switch outcome {
        case .completed, .limitReached, .refused, .stoppedAfterDeclines:
            memory.messages = Self.withoutPictures(messages)
            memory.taint = taint
            memory.lastActivity = context.now
        case .cancelled, .timedOut, .failed:
            guard !actions.isEmpty else { return base }
            memory.messages =
                base.messages + [
                    .user(AgentLoop.userTurn(command: command, context: context, fullControl: configuration.fullControl)),
                    LLMMessage(
                        role: .assistant,
                        content: [
                            .text("I was interrupted. Before that I had done: \(actions.joined(separator: "; ")).")
                        ]
                    ),
                ]
            memory.taint = taint
            memory.lastActivity = context.now
        }
        return memory
    }
}

/// The text the model has streamed this turn, for live display. Guarded by a lock because the stream callback is `@Sendable`.
final class StreamedText: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: "")

    func append(_ delta: String) -> String {
        state.withLock {
            $0 += delta
            return $0
        }
    }

    func reset() {
        state.withLock { $0 = "" }
    }
}

extension AgentRunResult.Outcome {
    /// A word for the audit trail and the log.
    public var auditWord: String {
        switch self {
        case .completed: "completed"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .limitReached: "limit"
        case .timedOut: "timeout"
        case .refused: "refused"
        case .stoppedAfterDeclines: "declined"
        }
    }
}

extension ConfirmationOutcome {
    public var auditWord: String {
        switch self {
        case .approved: "approved"
        case .denied: "denied"
        case .cancelled: "cancelled"
        case .timedOut: "timeout"
        }
    }
}
