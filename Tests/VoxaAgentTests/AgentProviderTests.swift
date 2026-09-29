import Foundation
import Testing
@testable import VoxaAgent
import VoxaCore
import VoxaLLM
import VoxaTestSupport

/// How the choice of model provider reaches the agent: in each request, in what counts as "the same settings", and in how a
/// failure is worded.
@Suite("Agent: model providers")
@MainActor
struct AgentProviderTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func service(
        _ turns: [ScriptedLLM.Turn],
        settings: @escaping @Sendable () async -> AppSettings
    ) -> (AgentService, ScriptedLLM) {
        let llm = ScriptedLLM(turns)
        let service = AgentService(
            llm: llm,
            registry: ToolRegistry([StubTool("look_up", risk: .readOnly, run: { _ in .text("ok") })]),
            confirmations: ScriptedConfirmations(),
            systemPrompt: SystemPrompt(template: "test {{max_steps}}"),
            clock: ManualClock(),
            settings: settings
        )
        return (service, llm)
    }

    // MARK: The request

    @Test("Claude is asked with no server address and no context window")
    func claude() async {
        let harness = LoopHarness([.response(.say("ok"))], settings: AppSettings(localeIdentifier: "en_US"))
        _ = await harness.run()
        let request = harness.llm.requests[0]
        #expect(request.provider == .anthropic)
        #expect(request.model == AppSettings.defaultModel)
        #expect(request.endpoint == nil)
        #expect(request.contextLength == nil)
    }

    @Test("OpenAI is asked with its own model and address")
    func openAI() async {
        let settings = AppSettings(
            localeIdentifier: "en_US",
            provider: .openAI,
            model: "claude-sonnet-5-5",
            openAIModel: "gpt-6-luna",
            openAIBaseURL: "https://gateway.example.com/v1"
        )
        let harness = LoopHarness([.response(.say("ok"))], settings: settings)
        _ = await harness.run()
        let request = harness.llm.requests[0]
        #expect(request.provider == .openAI)
        #expect(request.model == "gpt-6-luna", "the Claude model name isn't sent to OpenAI")
        #expect(request.endpoint?.absoluteString == "https://gateway.example.com/v1")
        #expect(request.contextLength == nil)
    }

    @Test("Ollama is asked with its model, its server, and the context window from Settings")
    func ollama() async {
        let settings = AppSettings(
            localeIdentifier: "en_US",
            provider: .ollama,
            ollamaModel: "qwen3:8b",
            ollamaBaseURL: "http://studio.local:11434",
            ollamaContextLength: 32_768
        )
        let harness = LoopHarness([.response(.say("ok"))], settings: settings)
        _ = await harness.run()
        let request = harness.llm.requests[0]
        #expect(request.provider == .ollama)
        #expect(request.model == "qwen3:8b")
        #expect(request.endpoint?.absoluteString == "http://studio.local:11434")
        #expect(request.contextLength == 32_768)
    }

    // MARK: Conversations

    @Test("switching provider between commands starts a fresh conversation")
    func providerChange() async {
        let box = SettingsBox(AppSettings(localeIdentifier: "en_US"))
        let (service, llm) = service([.response(.say("one")), .response(.say("two"))], settings: { await box.value })
        _ = await service.run("first", now: t0)
        await box.set(AppSettings(localeIdentifier: "en_US", provider: .openAI))
        _ = await service.run("second", now: t0.addingTimeInterval(10))
        #expect(llm.requests[1].messages.count == 1, "OpenAI must not be sent Claude's history")
        #expect(llm.requests[1].provider == .openAI)
    }

    @Test("pointing Ollama at another server or context size starts fresh; the same settings keep the conversation")
    func ollamaSettingsChange() async {
        let base = AppSettings(localeIdentifier: "en_US", provider: .ollama, ollamaModel: "qwen3:8b")
        let box = SettingsBox(base)
        let (service, llm) = service(
            [.response(.say("1")), .response(.say("2")), .response(.say("3")), .response(.say("4"))],
            settings: { await box.value }
        )
        _ = await service.run("a", now: t0)
        _ = await service.run("b", now: t0.addingTimeInterval(5))
        #expect(llm.requests[1].messages.count == 3, "unchanged settings keep the conversation")

        var moved = base
        moved.ollamaBaseURL = "http://studio.local:11434"
        await box.set(moved)
        _ = await service.run("c", now: t0.addingTimeInterval(10))
        #expect(llm.requests[2].messages.count == 1)

        var larger = moved
        larger.ollamaContextLength = 32_768
        await box.set(larger)
        _ = await service.run("d", now: t0.addingTimeInterval(15))
        #expect(llm.requests[3].messages.count == 1)
    }

    // MARK: Time

    @Test("a model on this Mac gets longer to finish a command than one across the network")
    func localModelsGetMoreTime() async {
        let (service, _) = service([], settings: { AppSettings() })
        let standard = await service.limits(for: .anthropic)
        #expect(await service.limits(for: .openAI) == standard)
        let local = await service.limits(for: .ollama)
        #expect(local.totalTimeout > standard.totalTimeout)
        #expect(local.perToolTimeout == standard.perToolTimeout)
        #expect(local.maxDeclines == standard.maxDeclines)
    }

    // MARK: Failures

    @Test("a failure is worded for the service that failed")
    func failureWording() async {
        let cases: [(ModelProvider, LLMError, String)] = [
            (.openAI, .quotaExceeded("x"), "OpenAI"),
            (.ollama, .unreachable("localhost"), "Ollama"),
        ]
        for (provider, error, name) in cases {
            let settings = AppSettings(localeIdentifier: "en_US", provider: provider, ollamaModel: "qwen3:8b")
            // Through the router, as the app has it: the clients throw plain errors and the router names the service.
            let scripted = ScriptedLLM([.failure(error)])
            let router = RoutingLLMClient(anthropic: scripted, openAI: scripted, ollama: scripted)
            let service = AgentService(
                llm: router,
                registry: ToolRegistry([]),
                confirmations: ScriptedConfirmations(),
                systemPrompt: SystemPrompt(template: "t"),
                clock: ManualClock(),
                settings: { settings }
            )
            let result = await service.run("hi", now: t0)
            guard case .failed(let failure) = result.outcome else { Issue.record("expected a failure, got \(result.outcome)"); continue }
            #expect(failure.title.contains(name), "\(failure.title)")
        }
    }

    @Test("a reply cut off by the length limit is reported in the words of the provider that was used")
    func cutOffWording() async {
        let settings = AppSettings(localeIdentifier: "en_US", provider: .ollama, ollamaModel: "qwen3:8b")
        let harness = LoopHarness([.response(LLMResponse(content: [.text("half")], stopReason: .maxTokens))], settings: settings)
        let result = await harness.run().result
        guard case .failed(let failure) = result.outcome else { Issue.record("expected a failure, got \(result.outcome)"); return }
        #expect(failure.title.contains("Ollama"))
    }
}

private actor SettingsBox {
    private(set) var value: AppSettings
    init(_ value: AppSettings) { self.value = value }
    func set(_ new: AppSettings) { value = new }
}
