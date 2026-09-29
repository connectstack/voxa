import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

/// A client that answers with one word, or fails, and remembers what it was asked.
private final class Stub: LLMClient, @unchecked Sendable {
    let word: String
    let failure: (any Error)?
    private let lock = NSLock()
    private var seen: [LLMRequest] = []

    init(word: String, failure: (any Error)? = nil) {
        self.word = word
        self.failure = failure
    }

    var requests: [LLMRequest] { lock.withLock { seen } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        lock.withLock { seen.append(request) }
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            continuation.yield(.messageStart(id: "m", model: "m", usage: nil))
            continuation.yield(.blockStart(index: 0, block: .text("")))
            continuation.yield(.blockDelta(index: 0, delta: .text(word)))
            continuation.yield(.blockStop(index: 0))
            continuation.yield(.messageDelta(stopReason: .endTurn, usage: nil))
            continuation.yield(.messageStop)
            continuation.finish()
        }
    }
}

@Suite("RoutingLLMClient")
struct RoutingLLMClientTests {
    private func request(_ provider: ModelProvider) -> LLMRequest {
        LLMRequest(model: "m", system: [SystemBlock("s")], messages: [.user("hi")], provider: provider)
    }

    @Test("each request goes to the client for its provider, and only that one")
    func routes() async throws {
        let claude = Stub(word: "claude"), openAI = Stub(word: "openai"), ollama = Stub(word: "ollama")
        let router = RoutingLLMClient(anthropic: claude, openAI: openAI, ollama: ollama)

        #expect(try await router.complete(request(.anthropic)).text == "claude")
        #expect(try await router.complete(request(.openAI)).text == "openai")
        #expect(try await router.complete(request(.ollama)).text == "ollama")
        #expect(try await router.complete(request(.openAI)).text == "openai")

        #expect(claude.requests.count == 1)
        #expect(openAI.requests.count == 2)
        #expect(ollama.requests.count == 1)
    }

    @Test("the request reaches the client unchanged")
    func passesRequestThrough() async throws {
        let ollama = Stub(word: "x")
        let router = RoutingLLMClient(anthropic: Stub(word: ""), openAI: Stub(word: ""), ollama: ollama)
        let original = LLMRequest(
            model: "qwen3:8b",
            system: [SystemBlock("s")],
            messages: [.user("hi")],
            effort: .low,
            provider: .ollama,
            endpoint: URL(string: "http://studio.local:11434"),
            contextLength: 32_768
        )
        _ = try await router.complete(original)
        #expect(ollama.requests == [original])
    }

    @Test("a failure is tagged with the provider it came from, so the wording names the right service")
    func tagsFailures() async {
        let router = RoutingLLMClient(
            anthropic: Stub(word: "", failure: LLMError.overloaded),
            openAI: Stub(word: "", failure: LLMError.quotaExceeded("out of credit")),
            ollama: Stub(word: "", failure: LLMError.unreachable("localhost"))
        )
        await #expect(throws: ProviderFailure(provider: .anthropic, error: .overloaded)) { try await router.complete(request(.anthropic)) }
        await #expect(throws: ProviderFailure(provider: .openAI, error: .quotaExceeded("out of credit"))) {
            try await router.complete(request(.openAI))
        }
        await #expect(throws: ProviderFailure(provider: .ollama, error: .unreachable("localhost"))) {
            try await router.complete(request(.ollama))
        }
    }

    @Test("an error that isn't the model client's own passes through as it is")
    func otherErrors() async {
        struct Odd: Error, Equatable {}
        let router = RoutingLLMClient(anthropic: Stub(word: "", failure: Odd()), openAI: Stub(word: ""), ollama: Stub(word: ""))
        await #expect(throws: Odd()) { try await router.complete(request(.anthropic)) }
    }

    @Test("the words shown for the same failure are about the service that failed")
    func wording() {
        let openAI = UserFacingError.describing(ProviderFailure(provider: .openAI, error: .quotaExceeded("x")))
        let ollama = UserFacingError.describing(ProviderFailure(provider: .ollama, error: .unreachable("localhost")))
        #expect(openAI.title.contains("OpenAI"))
        #expect(ollama.title.contains("Ollama"))
        #expect(ollama.recovery == .openOllama)
    }

    @Test("cancelling the caller cancels the request underneath")
    func cancellation() async {
        let transport = MockHTTPTransport([
            MockHTTPTransport.Response(chunks: SSE.chunked(OllamaNDJSON.textChunk("so far"), size: 20), holdOpen: true)
        ])
        let ollama = OllamaClient(transport: transport, discovery: FakeOllamaDiscovery())
        let router = RoutingLLMClient(anthropic: Stub(word: ""), openAI: Stub(word: ""), ollama: ollama)
        let task = Task { try await router.complete(request(.ollama)) }
        _ = await waitUntil { transport.requestCount == 1 }
        task.cancel()
        #expect(await waitUntil { transport.terminatedStreams == 1 })
    }
}
