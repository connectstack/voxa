import Foundation
import Testing
@testable import VoxaApp
import VoxaCore
import VoxaLLM
import VoxaTestSupport

@Suite("Provider connection test")
struct ProviderConnectionTests {
    private func test(
        _ turns: [ScriptedLLM.Turn], discovery: FakeOllamaDiscovery = FakeOllamaDiscovery(), settings: AppSettings = AppSettings()
    ) -> (ProviderConnectionTest, ScriptedLLM) {
        let llm = ScriptedLLM(turns)
        return (ProviderConnectionTest(llm: llm, ollama: discovery, settings: { settings }), llm)
    }

    private let ollamaSettings = AppSettings(provider: .anthropic, ollamaModel: "qwen3:8b", ollamaBaseURL: "http://localhost:11434", ollamaContextLength: 8_192)

    @Test("a provider that answers passes, and the request is a small one for that provider's own model")
    func passes() async {
        let settings = AppSettings(model: "claude-x", openAIModel: "gpt-x", openAIBaseURL: "https://gateway.example.com/v1")
        for provider in [ModelProvider.anthropic, .openAI] {
            let (test, llm) = test([.response(.say("OK"))], settings: settings)
            #expect(await test.run(provider) == nil)
            let request = llm.requests[0]
            #expect(request.provider == provider)
            #expect(request.model == (provider == .openAI ? "gpt-x" : "claude-x"))
            #expect(request.endpoint == (provider == .openAI ? URL(string: "https://gateway.example.com/v1") : nil))
            #expect(request.maxTokens <= 64)
            #expect(request.tools.isEmpty)
        }
    }

    @Test("the provider tested is the one asked about, not the one chosen in Settings")
    func testsTheAskedProvider() async {
        let (test, llm) = test([.response(.say("OK"))], settings: AppSettings(provider: .anthropic))
        _ = await test.run(.openAI)
        #expect(llm.requests[0].provider == .openAI)
    }

    @Test("a failure comes back in plain words")
    func fails() async {
        let (test, _) = test([.failure(ProviderFailure(provider: .openAI, error: .authentication("bad key")))])
        let failure = await test.run(.openAI)
        #expect(failure?.title.contains("OpenAI") == true)
    }

    @Test("Ollama is checked first: a model that isn't chosen, isn't installed or can't use tools is named before any chat")
    func ollamaChecks() async {
        let (none, llmNone) = test([], settings: AppSettings(ollamaModel: ""))
        #expect(await none.run(.ollama)?.title.contains("model") == true)
        #expect(llmNone.requestCount == 0)

        let (missing, llmMissing) = test([], discovery: FakeOllamaDiscovery(), settings: ollamaSettings)
        #expect(await missing.run(.ollama)?.title.contains("installed") == true)
        #expect(llmMissing.requestCount == 0)

        let plain = FakeOllamaDiscovery(details: ["qwen3:8b": OllamaModelDetails(capabilities: ["completion"])])
        let (noTools, llmNoTools) = test([], discovery: plain, settings: ollamaSettings)
        #expect(await noTools.run(.ollama)?.detail.contains("qwen3:8b") == true)
        #expect(llmNoTools.requestCount == 0)

        let down = FakeOllamaDiscovery(failure: LLMError.unreachable("localhost"))
        let (off, _) = test([], discovery: down, settings: ollamaSettings)
        let notRunning = await off.run(.ollama)
        #expect(notRunning?.title.contains("Ollama") == true)
        #expect(notRunning?.recovery == .openOllama)
    }

    @Test("with a capable model, Ollama gets a quick request with the context window from Settings")
    func ollamaPasses() async {
        let capable = FakeOllamaDiscovery(details: ["qwen3:8b": OllamaModelDetails(capabilities: ["tools"])])
        let (test, llm) = test([.response(.say("OK"))], discovery: capable, settings: ollamaSettings)
        #expect(await test.run(.ollama) == nil)
        let request = llm.requests[0]
        #expect(request.provider == .ollama)
        #expect(request.model == "qwen3:8b")
        #expect(request.effort == .low)
        #expect(request.contextLength == 8_192)
        #expect(request.endpoint?.absoluteString == "http://localhost:11434")
    }

    @Test("an unusable Ollama address is reported without a request")
    func ollamaBadAddress() async {
        let (test, llm) = test([], settings: AppSettings(ollamaModel: "qwen3:8b", ollamaBaseURL: "nonsense"))
        #expect(await test.run(.ollama)?.title == L10n.SettingsProvider.ollamaBadAddress)
        #expect(llm.requestCount == 0)
    }
}
