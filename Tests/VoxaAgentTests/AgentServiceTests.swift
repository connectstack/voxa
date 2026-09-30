import Foundation
import Testing
@testable import VoxaAgent
import VoxaCore
import VoxaLLM
import VoxaPolicy
import VoxaTestSupport

@Suite("ConversationMemory")
struct ConversationMemoryTests {
    private func memory(
        messages: Int = 2,
        at date: Date? = Date(timeIntervalSince1970: 1_000),
        fingerprint: String? = "f"
    ) -> ConversationMemory {
        var memory = ConversationMemory()
        memory.messages = (0..<messages).map {
            $0 % 2 == 0 ? .user("u\($0)") : LLMMessage(role: .assistant, content: [.text("a\($0)")])
        }
        memory.lastActivity = date
        memory.fingerprint = fingerprint
        var taint = RunTaint()
        taint.absorb(.text("x", provenance: .untrusted(source: "clipboard")))
        memory.taint = taint
        return memory
    }

    @Test("within the follow-up window and under the same settings, the conversation is kept")
    func kept() {
        var conversation = memory()
        #expect(conversation.prepare(now: Date(timeIntervalSince1970: 1_100), window: 120, fingerprint: "f") == nil)
        #expect(conversation.messages.count == 2)
        #expect(conversation.taint.isTainted)
    }

    @Test("after the window, it is forgotten, and the taint goes with it")
    func expired() {
        var conversation = memory()
        #expect(conversation.prepare(now: Date(timeIntervalSince1970: 1_121), window: 120, fingerprint: "f") == .expired)
        #expect(conversation.isEmpty)
        #expect(!conversation.taint.isTainted)
        #expect(conversation.fingerprint == "f")
    }

    @Test("a window of zero means no follow-ups at all")
    func noFollowUps() {
        var conversation = memory()
        #expect(conversation.prepare(now: Date(timeIntervalSince1970: 1_001), window: 0, fingerprint: "f") == .expired)
    }

    @Test("history built under other settings is dropped, because cached prefixes and signed reasoning wouldn't match")
    func settingsChanged() {
        var conversation = memory()
        #expect(
            conversation.prepare(now: Date(timeIntervalSince1970: 1_001), window: 120, fingerprint: "other") == .settingsChanged
        )
        #expect(conversation.isEmpty)
        #expect(conversation.fingerprint == "other")
    }

    @Test("a conversation that has grown too long starts over")
    func tooLong() {
        var many = memory(messages: ConversationMemory.maxMessages + 2)
        #expect(many.prepare(now: Date(timeIntervalSince1970: 1_001), window: 120, fingerprint: "f") == .tooLong)

        var big = ConversationMemory()
        big.messages = [.user(String(repeating: "x", count: ConversationMemory.maxCharacters + 1))]
        big.lastActivity = Date(timeIntervalSince1970: 1_000)
        big.fingerprint = "f"
        #expect(big.prepare(now: Date(timeIntervalSince1970: 1_001), window: 120, fingerprint: "f") == .tooLong)
    }

    @Test("a brand-new conversation just records the fingerprint")
    func fresh() {
        var conversation = ConversationMemory()
        #expect(conversation.prepare(now: Date(), window: 120, fingerprint: "f") == nil)
        #expect(conversation.fingerprint == "f")
    }
}

@Suite("AgentService")
@MainActor
struct AgentServiceTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(
        _ turns: [ScriptedLLM.Turn],
        tools: [any AgentTool] = [StubTool("look_up", risk: .readOnly, run: { _ in .text("ok") })],
        settings: @escaping @Sendable () async -> AppSettings = { AppSettings(localeIdentifier: "en_US") }
    ) -> (AgentService, ScriptedLLM) {
        let llm = ScriptedLLM(turns)
        let service = AgentService(
            llm: llm,
            registry: ToolRegistry(tools),
            confirmations: ScriptedConfirmations(),
            systemPrompt: SystemPrompt(template: "test {{max_steps}}"),
            clock: ManualClock(),
            settings: settings
        )
        return (service, llm)
    }

    @Test("a follow-up inside the window sees the earlier command; one after it doesn't")
    func followUpWindow() async {
        let (service, llm) = service([.response(.say("one")), .response(.say("two")), .response(.say("three"))])
        _ = await service.run("first", now: t0)
        #expect(await service.hasConversation)

        _ = await service.run("second", now: t0.addingTimeInterval(60))
        #expect(llm.requests[1].messages.count == 3, "first command, its reply, and the follow-up")

        _ = await service.run("third", now: t0.addingTimeInterval(60 + 121))
        #expect(llm.requests[2].messages.count == 1, "the window passed, so it starts fresh")
    }

    @Test("changing a setting between commands starts a fresh conversation")
    func settingsChange() async {
        let model = ModelBox()
        let (service, llm) = service(
            [.response(.say("one")), .response(.say("two"))],
            settings: { AppSettings(localeIdentifier: "en_US", model: await model.name) }
        )
        _ = await service.run("first", now: t0)
        await model.set("claude-opus-5-5")
        _ = await service.run("second", now: t0.addingTimeInterval(10))
        #expect(llm.requests[1].messages.count == 1)
        #expect(llm.requests[1].model == "claude-opus-5-5")
    }

    @Test("starting over forgets everything")
    func reset() async {
        let (service, llm) = service([.response(.say("one")), .response(.say("two"))])
        _ = await service.run("first", now: t0)
        await service.resetConversation()
        #expect(await !service.hasConversation)
        _ = await service.run("second", now: t0.addingTimeInterval(1))
        #expect(llm.requests[1].messages.count == 1)
    }

    @Test("a second command while one is running is refused, not interleaved")
    func busy() async {
        let (service, llm) = service([.hold, .response(.say("never"))])
        let first = Task { await service.run("first", now: t0) }
        #expect(await waitUntil { llm.requestCount == 1 })

        let second = await service.run("second", now: t0)
        #expect(second.reply == L10n.Agent.busy)
        #expect(llm.requestCount == 1)

        first.cancel()
        #expect(await first.value.outcome == .cancelled)
    }

    @Test("a command that may take many steps gets a clock to match: nine seconds a step, never less than two minutes")
    func clockFollowsSteps() async {
        let (service, _) = service([])
        #expect(await service.limits(for: .anthropic, steps: 5).totalTimeout == .seconds(120))
        #expect(await service.limits(for: .anthropic, steps: 12).totalTimeout == .seconds(120))
        #expect(await service.limits(for: .anthropic, steps: 20).totalTimeout == .seconds(180))
        #expect(await service.limits(for: .anthropic, steps: 40).totalTimeout == .seconds(360))
        let local = await service.limits(for: .ollama, steps: 5).totalTimeout
        #expect(local == AgentService.localModelTimeout, "a local model gets longer still")
        #expect(await service.limits(for: .anthropic).totalTimeout == .seconds(180), "the default number of steps is 20")
    }

    @Test("with every tool switched off it says so instead of calling the model")
    func everythingOff() async {
        let (service, llm) = service(
            [],
            settings: { AppSettings(localeIdentifier: "en_US", disabledTools: ["look_up"]) }
        )
        let result = await service.run("do something", now: t0)
        #expect(result.reply == L10n.Agent.noTools)
        #expect(llm.requestCount == 0)
    }
}

private actor ModelBox {
    private(set) var name = AppSettings.defaultModel
    func set(_ value: String) { name = value }
}
