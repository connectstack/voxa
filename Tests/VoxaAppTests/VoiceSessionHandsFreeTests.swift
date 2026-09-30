import Foundation
import Testing
import VoxaAgent
@testable import VoxaApp
import VoxaCore
import VoxaHUD
import VoxaTestSupport

@MainActor
@Suite("VoiceSessionController as the host of typed, spoken and Siri commands")
struct VoiceSessionHandsFreeTests {
    private func harness(_ script: FakeAgent.Script = FakeAgent.Script()) -> (SessionHarness, FakeAgent) {
        let agent = FakeAgent(script)
        return (SessionHarness(agent: agent), agent)
    }

    // MARK: Whether Voxa is free

    @Test("an idle session is ready for hands-free")
    func idle() {
        let (harness, _) = harness()
        #expect(harness.controller.handsFreeAvailability == .ready)
    }

    @Test("while the shortcut is held, or its audio is being turned into a command, the microphone is the shortcut's")
    func pushToTalk() async {
        let (harness, _) = harness(.init(holds: true))
        #expect(await harness.pressAndListen())
        #expect(harness.controller.handsFreeAvailability == .pushToTalk)
        await harness.holdLongEnough()
        harness.hotkeys.release()
        #expect(harness.controller.handsFreeAvailability == .pushToTalk)
    }

    @Test("while a command is being carried out Voxa is working, and afterwards it is ready again")
    func working() async {
        let (harness, agent) = harness(.init(holds: true))
        await harness.speakAndRelease()
        #expect(await waitUntil { agent.commands.count == 1 })
        #expect(harness.controller.handsFreeAvailability == .working)
        agent.release()
        #expect(await waitUntil { harness.controller.handsFreeAvailability != .working })
    }

    @Test("while Voxa is speaking, its microphone would hear it")
    func speaking() {
        let (harness, _) = harness()
        harness.speaker.speak("Opened Safari.", options: .init())
        #expect(harness.controller.handsFreeAvailability == .speaking)
        harness.speaker.finish()
        #expect(harness.controller.handsFreeAvailability == .ready)
    }

    // MARK: A command from the room

    @Test("a hands-free command goes to the agent exactly as a held one does, and the reply is shown and spoken")
    func submit() async {
        let (harness, agent) = harness(.init(result: AgentRunResult(outcome: .completed, reply: "Opened Safari.")))
        #expect(harness.controller.submitCommand("open Safari"))

        #expect(await waitUntil { agent.commands == ["open Safari"] })
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
        #expect(harness.hud.events.contains(.transcript("open Safari", isFinal: true)))
        #expect(harness.speaker.spoken.map(\.text) == ["Opened Safari."])
        #expect(agent.nows == [Date(timeIntervalSince1970: 1_800_000_000)])
    }

    @Test("it is busy the moment a command is taken, so the listener lets go of the microphone at once")
    func busyAtOnce() {
        let (harness, _) = harness(.init(holds: true))
        #expect(harness.controller.submitCommand("open Safari"))
        #expect(harness.controller.handsFreeAvailability == .working)
    }

    @Test("a second command is not taken while the first is running")
    func notTwice() async {
        let (harness, agent) = harness(.init(holds: true))
        #expect(harness.controller.submitCommand("open Safari"))
        #expect(!harness.controller.submitCommand("open Notes"))
        #expect(await waitUntil { agent.commands == ["open Safari"] })
        agent.release()
    }

    @Test("nothing is taken while the shortcut is held")
    func notDuringPushToTalk() async {
        let (harness, agent) = harness()
        #expect(await harness.pressAndListen())
        #expect(!harness.controller.submitCommand("open Safari"))
        #expect(agent.commands.isEmpty)
    }

    @Test("an empty command, or a session with no agent, takes nothing")
    func nothingToDo() {
        let (harness, agent) = harness()
        #expect(!harness.controller.submitCommand("   "))
        #expect(agent.commands.isEmpty)

        let bare = SessionHarness()
        #expect(!bare.controller.submitCommand("open Safari"))
    }

    @Test("a command starting is announced once, whoever gave it, so the bar can give the keyboard back")
    func announcesTheStart() async {
        let (harness, agent) = harness()
        var started = 0
        harness.controller.onCommandStarted = { started += 1 }

        #expect(harness.controller.submitCommand("open Safari"))
        #expect(started == 1)
        #expect(await waitUntil { agent.commands == ["open Safari"] })
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })

        // The push-to-talk key starts one too.
        harness.speaker.finish()
        await harness.speakAndRelease()
        #expect(await waitUntil { started == 2 })
    }

    @Test("a command that is refused does not announce a start")
    func refusedIsNotAStart() {
        let (harness, _) = harness(.init(holds: true))
        var started = 0
        harness.controller.onCommandStarted = { started += 1 }
        #expect(harness.controller.submitCommand("open Safari"))
        #expect(!harness.controller.submitCommand("open Notes"))
        #expect(!harness.controller.submitCommand("   "))
        #expect(started == 1)
    }

    @Test("Esc cancels a hands-free command, like any other")
    func escapeCancels() async {
        let (harness, agent) = harness(.init(holds: true))
        #expect(harness.controller.submitCommand("open Safari"))
        #expect(await waitUntil { agent.commands.count == 1 })
        harness.hotkeys.pressEscape()
        #expect(await waitUntil { agent.wasCancelled })
        #expect(await waitUntil { harness.controller.handsFreeAvailability == .ready })
    }

    @Test("an error left on screen is cleared by the next command")
    func clearsError() async {
        let error = UserFacingError(title: "Ollama isn't running", detail: "Open the Ollama app.")
        let failing = FakeAgent(.init(result: AgentRunResult(outcome: .failed(error), reply: error.title)))
        let harness = SessionHarness(agent: failing)
        harness.controller.submitCommand("open Safari")
        #expect(await waitUntil { harness.controller.lastError != nil })

        failing.script = .init(result: AgentRunResult(outcome: .completed, reply: "Opened Safari."))
        harness.speaker.finish()   // the error was spoken, and Voxa is not free until that is over
        #expect(harness.controller.submitCommand("open Safari again"))
        #expect(harness.controller.lastError == nil)
        #expect(await waitUntil { harness.hud.lastMode == .reply("Opened Safari.") })
    }
}
