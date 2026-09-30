import Foundation
import Testing
import VoxaAgent
@testable import VoxaApp
import VoxaCore
import VoxaTestSupport

@MainActor
@Suite("SiriCommand")
struct SiriCommandTests {
    @Test("what Siri heard is handed to Voxa as a command")
    func started() {
        let host = FakeHandsFreeHost()
        #expect(SiriCommand.run("open Safari", on: host) == .started)
        #expect(host.submitted == ["open Safari"])
    }

    @Test("the words are trimmed, and nothing at all is not a command")
    func trimming() {
        let host = FakeHandsFreeHost()
        #expect(SiriCommand.run("  open Safari \n", on: host) == .started)
        #expect(host.submitted == ["open Safari"])

        for empty in ["", "   ", "\n\t"] {
            #expect(SiriCommand.run(empty, on: FakeHandsFreeHost()) == .nothing)
        }
        let quiet = FakeHandsFreeHost()
        _ = SiriCommand.run("  ", on: quiet)
        #expect(quiet.submitted.isEmpty)
    }

    @Test("while Voxa is busy the command is not taken, and Siri is told", arguments: [
        HandsFreeAvailability.pushToTalk, .working, .speaking,
    ])
    func busy(availability: HandsFreeAvailability) {
        let host = FakeHandsFreeHost()
        host.availability = availability
        #expect(SiriCommand.run("open Safari", on: host) == .busy)
        #expect(host.submitted.isEmpty)
    }

    @Test("a command the session can't take is reported busy")
    func refused() {
        let host = FakeHandsFreeHost()
        host.accepts = false
        #expect(SiriCommand.run("open Safari", on: host) == .busy)
    }

    @Test("a second command while the first runs is not taken")
    func onlyOneAtATime() {
        let host = FakeHandsFreeHost()
        #expect(SiriCommand.run("open Safari", on: host) == .started)
        #expect(SiriCommand.run("open Notes", on: host) == .busy, "the host is working now")
        #expect(host.submitted == ["open Safari"])
    }

    @Test("through the real session it is a command like any other: the agent gets it, and the reply is shown")
    func throughTheSession() async {
        let agent = FakeAgent(.init(result: AgentRunResult(outcome: .completed, reply: "Opened Safari.")))
        let harness = SessionHarness(agent: agent)
        #expect(SiriCommand.run("open Safari", on: harness.controller) == .started)

        #expect(await waitUntil { agent.commands == ["open Safari"] })
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
        #expect(harness.speaker.spoken.map(\.text) == ["Opened Safari."])
    }

    @Test("nothing said to Siri can answer a question: while a command runs, the session takes no other")
    func cannotAnswerAQuestion() async {
        var script = FakeAgent.Script()
        script.holds = true
        let agent = FakeAgent(script)
        let confirmations = FakeConfirmations()
        let harness = SessionHarness(agent: agent, confirmations: confirmations)
        #expect(SiriCommand.run("delete my files", on: harness.controller) == .started)
        #expect(await waitUntil { agent.commands.count == 1 })

        confirmations.isAwaitingAnswer = true
        #expect(SiriCommand.run("yes", on: harness.controller) == .busy)
        #expect(confirmations.answers.isEmpty, "Siri's words are never an answer")
        #expect(agent.commands == ["delete my files"])
        agent.release()
    }
}
