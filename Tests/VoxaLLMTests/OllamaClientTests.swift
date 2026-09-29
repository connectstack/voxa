import Foundation
import os
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("OllamaClient")
@MainActor
struct OllamaClientTests {
    private let noJitter = RetryPolicy(
        maxAttempts: 2, baseDelay: .milliseconds(800), maxDelay: .seconds(4), jitter: 0, maxRetryAfter: .seconds(20)
    )

    private func client(
        _ transport: MockHTTPTransport,
        discovery: FakeOllamaDiscovery = FakeOllamaDiscovery(),
        clock: ManualClock = ManualClock(),
        baseURL: URL = OllamaClient.defaultBaseURL
    ) -> OllamaClient {
        OllamaClient(transport: transport, baseURL: baseURL, retryPolicy: noJitter, clock: clock, discovery: discovery)
    }

    private func request(model: String = "qwen3:8b", effort: ReasoningEffort? = nil, endpoint: URL? = nil) -> LLMRequest {
        LLMRequest(
            model: model,
            system: [SystemBlock("sys")],
            messages: [.user("hi")],
            effort: effort,
            provider: .ollama,
            endpoint: endpoint,
            contextLength: 8_192
        )
    }

    private func release(_ clock: ManualClock, by duration: Duration) async {
        _ = await clock.waitForSleepers()
        clock.advance(by: duration)
    }

    // MARK: Success

    @Test("an answer streams through, however the bytes are chunked", arguments: [1, 9, 64, 100_000])
    func streams(chunkSize: Int) async throws {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["Hello — ", "café."]), chunkSize: chunkSize)])
        let response = try await client(transport).complete(request())
        #expect(response.text == "Hello — café.")
        #expect(response.stopReason == .endTurn)
    }

    @Test("a tool call comes back ready to run")
    func toolCall() async throws {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.toolCallResponse(name: "open_app", arguments: ["name": "Safari"]))])
        let response = try await client(transport).complete(request())
        #expect(response.stopReason == .toolUse)
        #expect(response.executableToolUses.map(\.name) == ["open_app"])
        #expect(response.executableToolUses.first?.input == ["name": "Safari"])
    }

    @Test("the request goes to the local server with no credentials, and asks for the configured context window")
    func requestContents() async throws {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["ok"]))])
        _ = try await client(transport).complete(request())

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(sent.value(forHTTPHeaderField: "authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(transport.body(ofRequest: 0)?["options"]?["num_ctx"] == 8_192)
    }

    // MARK: Failures that are not retried

    @Test("with no model chosen nothing is sent")
    func missingModel() async {
        let transport = MockHTTPTransport([])
        await #expect(throws: LLMError.missingModel) { try await client(transport).complete(request(model: "  ")) }
        #expect(transport.requestCount == 0)
    }

    @Test("a model that isn't installed is named, and not retried")
    func notInstalled() async {
        let transport = MockHTTPTransport([.ollamaError(status: 404, message: "model 'llama9' not found")])
        await #expect(throws: LLMError.modelNotInstalled("llama9")) { try await client(transport).complete(request(model: "llama9")) }
        #expect(transport.requestCount == 1)
    }

    @Test("a model that can't call tools is named, and not retried")
    func noTools() async {
        let transport = MockHTTPTransport([.ollamaError(status: 400, message: "registry.ollama.ai/library/gemma2:2b does not support tools")])
        await #expect(throws: LLMError.modelCannotUseTools("gemma2:2b")) {
            try await client(transport).complete(request(model: "gemma2:2b"))
        }
        #expect(transport.requestCount == 1)
    }

    @Test("nothing listening is reported as the server not running, at once")
    func unreachable() async {
        let transport = MockHTTPTransport([MockHTTPTransport.Response(sendFailure: URLError(.cannotConnectToHost))])
        await #expect(throws: LLMError.unreachable("localhost")) { try await client(transport).complete(request()) }
        #expect(transport.requestCount == 1)
    }

    @Test("other bad requests come back with the server's own words")
    func badRequest() async {
        let transport = MockHTTPTransport([.ollamaError(status: 400, message: "invalid options: num_ctx")])
        await #expect(throws: LLMError.badRequest("invalid options: num_ctx")) { try await client(transport).complete(request()) }
        #expect(transport.requestCount == 1)
    }

    @Test("a server error that mentions nothing special is retried once, then reported")
    func serverErrorGivesUp() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .ollamaError(status: 500, message: "llama runner process has terminated"),
            .ollamaError(status: 500, message: "llama runner process has terminated"),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request()) }
        await release(clock, by: .milliseconds(800))
        await #expect(throws: LLMError.self) { try await task.value }
        #expect(transport.requestCount == 2)
    }

    // MARK: Retries

    @Test("a stream that dies mid-answer is retried, and the consumer is told to discard the partial")
    func midStreamFailure() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .stream(OllamaNDJSON.textChunk("half of an ans"), then: URLError(.networkConnectionLost)),
            .stream(OllamaNDJSON.textResponse(["the whole answer"])),
        ])
        let restarts = OSAllocatedUnfairLock(initialState: 0)
        let task = Task { () -> LLMResponse in
            try await client(transport, clock: clock).complete(request()) { event in
                if case .restarted = event { restarts.withLock { $0 += 1 } }
            }
        }
        await release(clock, by: .milliseconds(800))
        #expect(try await task.value.text == "the whole answer")
        #expect(restarts.withLock { $0 } == 1)
    }

    @Test("a body that ends without a done line counts as a dropped connection")
    func truncated() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .stream(OllamaNDJSON.textChunk("cut")),
            .stream(OllamaNDJSON.textResponse(["complete"])),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request()) }
        await release(clock, by: .milliseconds(800))
        #expect(try await task.value.text == "complete")
    }

    // MARK: Thinking

    private func details(_ thinking: OllamaModelDetails.Thinking) -> FakeOllamaDiscovery {
        FakeOllamaDiscovery(details: ["qwen3:8b": OllamaModelDetails(capabilities: ["tools"], thinking: thinking)])
    }

    private func sentThink(_ thinking: OllamaModelDetails.Thinking, effort: ReasoningEffort?) async throws -> JSONValue? {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["ok"]))])
        _ = try await client(transport, discovery: details(thinking)).complete(request(effort: effort))
        return transport.body(ofRequest: 0)?["think"]
    }

    @Test("a model whose thinking can be switched is told not to think when the setting is quick")
    func toggleQuick() async throws {
        #expect(try await sentThink(.toggle, effort: .low) == false)
        #expect(try await sentThink(.toggle, effort: .medium) == nil, "the model's own default applies")
        #expect(try await sentThink(.toggle, effort: .high) == nil)
    }

    @Test("a model with named levels gets the matching one, or none if it has no such level")
    func levels() async throws {
        #expect(try await sentThink(.levels(["low", "medium", "high"]), effort: .high) == "high")
        #expect(try await sentThink(.levels(["low", "high"]), effort: .medium) == nil)
    }

    @Test("a model that never thinks, or always does, is not sent a setting")
    func fixedModels() async throws {
        #expect(try await sentThink(.unsupported, effort: .low) == nil)
        #expect(try await sentThink(.always, effort: .low) == nil)
    }

    @Test("no effort setting means no question to the server and no setting sent")
    func noEffort() async throws {
        let discovery = details(.toggle)
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["ok"]))])
        _ = try await client(transport, discovery: discovery).complete(request(effort: nil))
        #expect(transport.body(ofRequest: 0)?["think"] == nil)
        #expect(discovery.detailCalls == 0)
    }

    @Test("if the model's details can't be read, the request goes ahead without a setting")
    func detailsUnavailable() async throws {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["ok"]))])
        let discovery = FakeOllamaDiscovery(failure: LLMError.unreachable("localhost"))
        let response = try await client(transport, discovery: discovery).complete(request(effort: .low))
        #expect(response.text == "ok")
        #expect(transport.body(ofRequest: 0)?["think"] == nil)
    }

    @Test("what a model can do is asked once, not for every step of a command")
    func detailsCached() async throws {
        let discovery = details(.toggle)
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["one"])), .stream(OllamaNDJSON.textResponse(["two"]))])
        let ollama = client(transport, discovery: discovery)
        _ = try await ollama.complete(request(effort: .low))
        _ = try await ollama.complete(request(effort: .low))
        #expect(discovery.detailCalls == 1)
    }

    @Test("if the server rejects the thinking setting, the request is repeated without it")
    func thinkRejected() async throws {
        let transport = MockHTTPTransport([
            .ollamaError(status: 400, message: "\"qwen3:8b\" does not support thinking"),
            .stream(OllamaNDJSON.textResponse(["ok"])),
        ])
        let response = try await client(transport, discovery: details(.toggle)).complete(request(effort: .low))
        #expect(response.text == "ok")
        #expect(transport.requestCount == 2)
        #expect(transport.body(ofRequest: 0)?["think"] == false)
        #expect(transport.body(ofRequest: 1)?["think"] == nil)
    }

    @Test("an unrelated 400 is not mistaken for a thinking problem")
    func unrelatedBadRequest() async {
        let transport = MockHTTPTransport([.ollamaError(status: 400, message: "invalid tool schema")])
        await #expect(throws: LLMError.badRequest("invalid tool schema")) {
            try await client(transport, discovery: details(.toggle)).complete(request(effort: .low))
        }
        #expect(transport.requestCount == 1)
    }

    // MARK: Cancellation and addresses

    @Test("cancelling the caller stops the request and releases the connection")
    func cancellation() async {
        let transport = MockHTTPTransport([
            MockHTTPTransport.Response(chunks: SSE.chunked(OllamaNDJSON.textChunk("so far"), size: 20), holdOpen: true)
        ])
        let task = Task { try await client(transport).complete(request()) }
        _ = await waitUntil { transport.requestCount == 1 }
        task.cancel()
        #expect(await waitUntil { transport.terminatedStreams == 1 })
        #expect(transport.requestCount == 1)
    }

    @Test("an address from Settings is used, cleaned up, and may be another machine on the network")
    func endpointFromSettings() async throws {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["ok"]))])
        _ = try await client(transport).complete(request(endpoint: URL(string: "http://studio.local:11434/v1/")!))
        #expect(transport.requests.first?.url?.absoluteString == "http://studio.local:11434/api/chat")
    }

    @Test("an address that isn't http or https is ignored")
    func oddEndpoint() async throws {
        let transport = MockHTTPTransport([.stream(OllamaNDJSON.textResponse(["ok"]))])
        _ = try await client(transport).complete(request(endpoint: URL(string: "file:///tmp/x")!))
        #expect(transport.requests.first?.url?.absoluteString == "http://localhost:11434/api/chat")
    }
}
