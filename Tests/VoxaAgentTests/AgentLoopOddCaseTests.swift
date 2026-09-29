import Foundation
import Testing
@testable import VoxaAgent
import VoxaCore
import VoxaLLM
import VoxaPolicy
import VoxaTestSupport

/// Approves, but the command is cancelled at that very moment (Esc pressed as the user clicked Allow).
private struct ApproveWhileCancelling: ConfirmationProviding {
    func confirm(_ prompt: ConfirmationPrompt) async -> ConfirmationOutcome {
        withUnsafeCurrentTask { $0?.cancel() }
        return .approved
    }
}

@Suite("AgentLoop: races and odd responses")
@MainActor
struct AgentLoopOddCaseTests {
    @Test("an approval that arrives together with a cancellation starts nothing")
    func approvalRacesCancellation() async {
        let tool = stub("wipe", .sensitive)
        let llm = ScriptedLLM([.response(.call("wipe")), .response(.say("never reached"))])
        let loop = AgentLoop(
            llm: llm,
            registry: ToolRegistry([tool]),
            confirmations: ApproveWhileCancelling(),
            systemPrompt: SystemPrompt(template: "test"),
            clock: ManualClock()
        )
        let output = await loop.run(
            command: "wipe it",
            memory: ConversationMemory(),
            configuration: AgentRunConfiguration(AppSettings(localeIdentifier: "en_US")),
            context: LoopHarness.context
        )
        #expect(output.result.outcome == .cancelled)
        #expect(tool.recorder.isEmpty, "the action must not run after the command was cancelled")
        #expect(llm.requestCount == 1)
    }

    @Test("a final answer that still carries a tool call keeps the words and drops the call, so the next command is valid")
    func endTurnWithToolCall() async {
        let tool = stub("look_up", .readOnly)
        let response = LLMResponse(
            content: [.text("All done."), .toolUse(id: "toolu_stray", name: "look_up", input: [:])],
            stopReason: .endTurn
        )
        let first = LoopHarness([.response(response)], tools: [tool])
        let output = await first.run("do it")

        #expect(output.result.outcome == .completed)
        #expect(output.result.reply == "All done.")
        #expect(tool.recorder.isEmpty, "a call in a finished turn is never run")
        for message in output.memory.messages {
            for block in message.content {
                if case .toolUse = block { Issue.record("a tool call without a result stayed in the history") }
            }
        }

        // The next command builds on that history without a dangling call in it.
        let second = LoopHarness([.response(.say("ok"))], tools: [tool])
        _ = await second.run("and again", memory: output.memory)
        let sent = second.llm.requests[0].messages
        #expect(sent.count == 3)
        #expect(sent.allSatisfy { message in
            !message.content.contains { if case .toolUse = $0 { true } else { false } }
        })
    }

    @Test("a final answer made only of a tool call still leaves a valid, non-empty turn")
    func endTurnWithOnlyAToolCall() async {
        let response = LLMResponse(content: [.toolUse(id: "toolu_stray", name: "look_up", input: [:])], stopReason: .endTurn)
        let harness = LoopHarness([.response(response)], tools: [stub("look_up", .readOnly)])
        let output = await harness.run()
        #expect(output.memory.messages.last?.content == [.text(L10n.Agent.noReply)])
    }
}
