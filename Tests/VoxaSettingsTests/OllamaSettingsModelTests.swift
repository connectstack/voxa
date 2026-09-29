import Foundation
import Testing
import VoxaCore
import VoxaLLM
@testable import VoxaSettings
import VoxaTestSupport

@MainActor
@Suite("Ollama settings")
struct OllamaSettingsModelTests {
    private let address = "http://localhost:11434"

    private func models(_ names: String...) -> [OllamaModel] {
        names.map { OllamaModel(name: $0, isCloud: $0.hasSuffix("-cloud")) }
    }

    @Test("a running server is reported with its version, and its models are listed in a sensible order")
    func running() async {
        let discovery = FakeOllamaDiscovery(models: models("qwen3:8b", "llama3.1:8b", "llama3.1:70b", "gemma2:2b"))
        let model = OllamaSettingsModel(discovery: discovery)
        await model.refresh(address: address, chosen: "")

        #expect(model.status == .running(version: "0.0.0-test"))
        #expect(model.isRunning)
        #expect(model.models.map(\.name) == ["gemma2:2b", "llama3.1:8b", "llama3.1:70b", "qwen3:8b"])
    }

    @Test("nothing listening is reported as not running, and clears what was known")
    func notRunning() async {
        let model = OllamaSettingsModel(discovery: FakeOllamaDiscovery(models: models("qwen3:8b")))
        await model.refresh(address: address, chosen: "")
        #expect(!model.models.isEmpty)

        let gone = OllamaSettingsModel(discovery: FakeOllamaDiscovery(failure: LLMError.unreachable("localhost")))
        await gone.refresh(address: address, chosen: "qwen3:8b")
        #expect(gone.status == .notRunning)
        #expect(gone.models.isEmpty)
        #expect(gone.details == nil)
    }

    @Test("an address that can't be a server is a problem, not a request", arguments: ["", "not a url", "ftp://localhost", "http://"])
    func badAddress(_ text: String) async {
        let discovery = FakeOllamaDiscovery(models: models("qwen3:8b"))
        let model = OllamaSettingsModel(discovery: discovery)
        await model.refresh(address: text, chosen: "")
        #expect(model.status == .problem(L10n.SettingsProvider.ollamaBadAddress))
        #expect(model.models.isEmpty)
    }

    @Test("what the chosen model can do is looked up, once it is known to be installed")
    func details() async {
        let discovery = FakeOllamaDiscovery(
            models: models("qwen3:8b", "gemma2:2b"),
            details: [
                "qwen3:8b": OllamaModelDetails(capabilities: ["tools", "thinking"], thinking: .toggle),
                "gemma2:2b": OllamaModelDetails(capabilities: ["completion"]),
            ]
        )
        let model = OllamaSettingsModel(discovery: discovery)

        await model.refresh(address: address, chosen: "qwen3:8b")
        #expect(model.details?.supportsTools == true)

        await model.loadDetails(of: "gemma2:2b", address: address)
        #expect(model.details?.supportsTools == false, "so Settings can warn that this one can't act")
    }

    @Test("a model that isn't installed, or none chosen, has no details and asks the server nothing")
    func noDetails() async {
        let discovery = FakeOllamaDiscovery(models: models("qwen3:8b"))
        let model = OllamaSettingsModel(discovery: discovery)
        await model.refresh(address: address, chosen: "llama9")
        #expect(model.details == nil)
        await model.loadDetails(of: "", address: address)
        #expect(model.details == nil)
        #expect(discovery.detailCalls == 0)
    }

    @Test("an installed model is found by name, and cloud models are marked")
    func lookup() async {
        let model = OllamaSettingsModel(discovery: FakeOllamaDiscovery(models: models("qwen3:8b", "gpt-oss:120b-cloud")))
        await model.refresh(address: address, chosen: "")
        #expect(model.installed("qwen3:8b")?.isCloud == false)
        #expect(model.installed("gpt-oss:120b-cloud")?.isCloud == true)
        #expect(model.installed("nope") == nil)
    }

    @Test("an address with a pasted API path still reaches the server")
    func addressCleanup() {
        #expect(OllamaClient.address(from: " http://localhost:11434/v1/ ")?.absoluteString == "http://localhost:11434")
        #expect(OllamaClient.address(from: "https://ollama.example.com")?.absoluteString == "https://ollama.example.com")
        #expect(OllamaClient.address(from: "localhost:11434") == nil, "without a scheme it isn't a URL Voxa can use")
    }
}
