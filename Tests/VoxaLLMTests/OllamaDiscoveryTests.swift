import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("OllamaDiscovery")
struct OllamaDiscoveryTests {
    private let base = URL(string: "http://localhost:11434")!

    private func discovery(_ responses: [MockHTTPTransport.Response]) -> (OllamaDiscovery, MockHTTPTransport) {
        let transport = MockHTTPTransport(responses)
        return (OllamaDiscovery(transport: transport), transport)
    }

    // MARK: Server and models

    @Test("the version comes from /api/version")
    func version() async throws {
        let (discovery, transport) = discovery([.json(status: 200, ["version": "0.12.3"])])
        #expect(try await discovery.version(at: base) == "0.12.3")
        #expect(transport.requests.first?.url?.absoluteString == "http://localhost:11434/api/version")
        #expect((transport.requests.first?.httpMethod ?? "GET") == "GET")
    }

    @Test("installed models are listed with what Settings shows about them, and cloud ones are flagged")
    func models() async throws {
        let (discovery, transport) = discovery([
            .json(status: 200, [
                "models": [
                    ["name": "qwen3:8b", "model": "qwen3:8b", "size": 5_225_388_164.0,
                     "details": ["family": "qwen3", "parameter_size": "8.2B", "quantization_level": "Q4_K_M"]],
                    [
                        "name": "gpt-oss:120b-cloud", "model": "gpt-oss:120b-cloud", "size": 384,
                        "remote_host": "https://ollama.com:443", "remote_model": "gpt-oss:120b",
                    ],
                    ["name": "llama3.2:3b", "size": 2_019_393_189.0],
                    ["nonsense": true],
                ]
            ])
        ])
        let models = try await discovery.models(at: base)
        #expect(transport.requests.first?.url?.path == "/api/tags")
        #expect(models.map(\.name) == ["qwen3:8b", "gpt-oss:120b-cloud", "llama3.2:3b"])

        let local = try #require(models.first)
        #expect(local.parameterSize == "8.2B" && local.family == "qwen3" && local.quantization == "Q4_K_M")
        #expect(local.sizeBytes == 5_225_388_164)
        #expect(!local.isCloud)
        #expect(models[1].isCloud)
        #expect(!models[2].isCloud)
    }

    @Test("a server with no models gives an empty list")
    func noModels() async throws {
        let (discovery, _) = discovery([.json(status: 200, ["models": []])])
        #expect(try await discovery.models(at: base).isEmpty)
    }

    // MARK: Capabilities

    @Test("a model's abilities come from /api/show")
    func details() async throws {
        let (discovery, transport) = discovery([
            .json(status: 200, [
                "capabilities": ["completion", "tools", "thinking"],
                "thinking": ["values": [false, true]],
                "model_info": ["general.architecture": "qwen3", "qwen3.context_length": 40_960, "qwen3.block_count": 36],
            ])
        ])
        let details = try await discovery.details(of: "qwen3:8b", at: base)
        #expect(details.supportsTools)
        #expect(details.thinking == .toggle)
        #expect(details.contextLength == 40_960)

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.path == "/api/show")
        #expect(sent.httpMethod == "POST")
        #expect(transport.body(ofRequest: 0)?["model"] == "qwen3:8b")
    }

    @Test("a model without tools or thinking says so")
    func plainModel() async throws {
        let (discovery, _) = discovery([.json(status: 200, ["capabilities": ["completion"]])])
        let details = try await discovery.details(of: "gemma2:2b", at: base)
        #expect(!details.supportsTools)
        #expect(details.thinking == .unsupported)
        #expect(details.contextLength == nil)
    }

    private static let thinkingCases: [(String?, [String], OllamaModelDetails.Thinking)] = [
        (#"{"values": ["low", "medium", "high"]}"#, ["thinking"], .levels(["low", "medium", "high"])),
        (#"{"values": [false, true]}"#, ["thinking"], .toggle),
        (#"{"values": [true]}"#, ["thinking"], .always),
        (nil, ["thinking"], .toggle),
        (nil, ["tools"], .unsupported),
        (#"{"values": []}"#, [], .unsupported),
    ]

    @Test("how a model thinks is read from the descriptor, or from the capability list on older servers", arguments: thinkingCases)
    func thinkingDescriptor(descriptor: String?, capabilities: [String], expected: OllamaModelDetails.Thinking) throws {
        let value = try descriptor.map { try JSONValue.parse($0) }
        #expect(OllamaDiscovery.thinking(from: value, capabilities: Set(capabilities)) == expected)
    }

    // MARK: Failures

    @Test("a missing model is named")
    func missingModel() async {
        let (discovery, _) = discovery([.ollamaError(status: 404, message: "model 'nope' not found")])
        await #expect(throws: LLMError.modelNotInstalled("nope")) { try await discovery.details(of: "nope", at: base) }
    }

    @Test("nothing listening is reported as the server not running")
    func unreachable() async {
        let (discovery, _) = discovery([MockHTTPTransport.Response(sendFailure: URLError(.cannotConnectToHost))])
        await #expect(throws: LLMError.unreachable("localhost")) { try await discovery.version(at: base) }
    }

    @Test("a reply that isn't JSON is an error, not a crash")
    func garbage() async {
        let (discovery, _) = discovery([MockHTTPTransport.Response(chunks: [Data("<html>proxy error</html>".utf8)])])
        await #expect(throws: LLMError.self) { try await discovery.models(at: base) }
    }
}
