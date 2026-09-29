import Foundation
import os
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("OpenAIClient")
@MainActor
struct OpenAIClientTests {
    private let noJitter = RetryPolicy(
        maxAttempts: 3, baseDelay: .milliseconds(600), maxDelay: .seconds(8), jitter: 0, maxRetryAfter: .seconds(20)
    )

    private func client(
        _ transport: MockHTTPTransport,
        key: String? = "sk-openai-test",
        clock: ManualClock = ManualClock(),
        baseURL: URL = OpenAIClient.officialBaseURL
    ) -> OpenAIClient {
        OpenAIClient(keys: InMemoryAPIKeyStore(key: key), transport: transport, baseURL: baseURL, retryPolicy: noJitter, clock: clock)
    }

    private func request(model: String = "gpt-6-luna", effort: ReasoningEffort? = .low, endpoint: URL? = nil) -> LLMRequest {
        LLMRequest(
            model: model, system: [SystemBlock("sys")], messages: [.user("hi")], effort: effort, provider: .openAI, endpoint: endpoint
        )
    }

    private func release(_ clock: ManualClock, by duration: Duration) async {
        _ = await clock.waitForSleepers()
        clock.advance(by: duration)
    }

    // MARK: Success

    @Test("an answer streams through, however the bytes are chunked", arguments: [1, 7, 64, 100_000])
    func streams(chunkSize: Int) async throws {
        let transport = MockHTTPTransport([.stream(OpenAISSE.textResponse("Hello — café."), chunkSize: chunkSize)])
        let response = try await client(transport).complete(request())
        #expect(response.text == "Hello — café.")
        #expect(response.stopReason == .endTurn)
    }

    @Test("a tool call comes back ready to run")
    func toolCall() async throws {
        let transport = MockHTTPTransport([
            .stream(OpenAISSE.toolCallResponse(name: "open_app", input: ["name": "Safari"], callID: "call_3"))
        ])
        let response = try await client(transport).complete(request())
        #expect(response.stopReason == .toolUse)
        #expect(response.executableToolUses.map(\.id) == ["call_3"])
        #expect(response.executableToolUses.first?.input == ["name": "Safari"])
    }

    @Test("the request carries the key as a bearer token, the effort, and no state on the server")
    func requestContents() async throws {
        let transport = MockHTTPTransport([.stream(OpenAISSE.textResponse("ok"))])
        _ = try await client(transport).complete(request())

        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.value(forHTTPHeaderField: "authorization") == "Bearer sk-openai-test")
        let body = try #require(transport.body(ofRequest: 0))
        #expect(body["store"] == false)
        #expect(body["reasoning"] == ["effort": "low"])
        #expect(String(data: try #require(sent.httpBody), encoding: .utf8)?.contains("sk-openai-test") == false)
    }

    // MARK: Failures that are not retried

    @Test("without a key nothing is sent")
    func missingKey() async {
        let transport = MockHTTPTransport([])
        await #expect(throws: LLMError.missingAPIKey) { try await client(transport, key: nil).complete(request()) }
        #expect(transport.requestCount == 0)
    }

    @Test("client errors fail at once with a specific error")
    func clientErrors() async {
        let cases: [(MockHTTPTransport.Response, LLMError)] = [
            (
                .openAIError(status: 401, code: "invalid_api_key", message: "Incorrect API key"),
                .authentication("Incorrect API key")
            ),
            (
                .openAIError(status: 403, code: "unsupported_country_region_territory", message: "not available here"),
                .permissionDenied("not available here")
            ),
            (
                .openAIError(status: 404, code: "model_not_found", message: "The model does not exist"),
                .modelNotFound("The model does not exist")
            ),
            (.openAIError(status: 400, message: "bad field"), .badRequest("bad field")),
            (.openAIError(status: 400, code: "context_length_exceeded", message: "too long"), .requestTooLarge),
            (
                .openAIError(
                    status: 429, code: "insufficient_quota", type: "insufficient_quota", message: "You exceeded your current quota"
                ),
                .quotaExceeded("You exceeded your current quota")
            ),
        ]
        for (response, expected) in cases {
            let transport = MockHTTPTransport([response])
            await #expect(throws: expected) { try await client(transport).complete(request()) }
            #expect(transport.requestCount == 1, "\(expected) must not be retried")
        }
    }

    @Test("running out of credit is not treated as a rate limit that will pass")
    func quotaIsNotRetried() {
        #expect(!LLMError.quotaExceeded("x").isRetryable)
        #expect(LLMError.rateLimited(retryAfter: nil).isRetryable)
    }

    // MARK: Retries

    @Test("a rate limit waits as long as retry-after says, then succeeds")
    func rateLimited() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .openAIError(status: 429, code: "rate_limit_exceeded", type: "requests", message: "slow down", headers: ["retry-after": "2"]),
            .stream(OpenAISSE.textResponse("ok")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request()) }
        await release(clock, by: .seconds(2))
        #expect(try await task.value.text == "ok")
        #expect(transport.requestCount == 2)
    }

    @Test("server errors back off and then succeed")
    func serverErrors() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .openAIError(status: 503, type: "server_error", message: "overloaded"),
            .openAIError(status: 500, type: "server_error", message: "oops"),
            .stream(OpenAISSE.textResponse("finally")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request()) }
        await release(clock, by: .milliseconds(600))
        #expect(await waitUntil { transport.requestCount == 2 })
        await release(clock, by: .milliseconds(1_200))
        #expect(try await task.value.text == "finally")
        #expect(transport.requestCount == 3)
    }

    @Test("a stream that dies mid-answer is retried, and the consumer is told to discard the partial")
    func midStreamFailure() async throws {
        let clock = ManualClock()
        // Everything but the closing events of the item, so the stream stops mid-answer.
        let partial = OpenAISSE.created(id: "resp_old")
            + OpenAISSE.message(pieces: ["half of an ans"])
            .replacingOccurrences(of: "event: response.output_item.done", with: "event: ping")
        let transport = MockHTTPTransport([
            .stream(partial, then: URLError(.networkConnectionLost)),
            .stream(OpenAISSE.textResponse("the whole answer", id: "resp_new")),
        ])
        let restarts = OSAllocatedUnfairLock(initialState: 0)
        let task = Task { () -> LLMResponse in
            try await client(transport, clock: clock).complete(request()) { event in
                if case .restarted = event { restarts.withLock { $0 += 1 } }
            }
        }
        await release(clock, by: .milliseconds(600))
        let response = try await task.value
        #expect(response.text == "the whole answer")
        #expect(restarts.withLock { $0 } == 1)
    }

    @Test("an error event inside a healthy stream is retried when it is transient")
    func transientStreamError() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .stream(OpenAISSE.created() + OpenAISSE.failed(code: "server_error", message: "hiccup")),
            .stream(OpenAISSE.textResponse("recovered")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request()) }
        await release(clock, by: .milliseconds(600))
        #expect(try await task.value.text == "recovered")
    }

    @Test("a body that ends without response.completed counts as a dropped connection")
    func truncated() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .stream(OpenAISSE.created() + OpenAISSE.message(pieces: ["cut"])),
            .stream(OpenAISSE.textResponse("complete")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request()) }
        await release(clock, by: .milliseconds(600))
        #expect(try await task.value.text == "complete")
    }

    // MARK: Adapting to the model

    @Test("if the model doesn't take a reasoning setting, the request is repeated without it")
    func reasoningRejected() async throws {
        let transport = MockHTTPTransport([
            .openAIError(status: 400, message: "Unsupported parameter: 'reasoning.effort' is not supported with this model."),
            .stream(OpenAISSE.textResponse("ok")),
        ])
        let response = try await client(transport).complete(request(model: "gpt-5-chat-latest"))
        #expect(response.text == "ok")
        #expect(transport.requestCount == 2)
        #expect(transport.body(ofRequest: 0)?["reasoning"] != nil)
        #expect(transport.body(ofRequest: 1)?["reasoning"] == nil)
    }

    @Test("if the server doesn't know the phase label, the request is repeated without it, and reasoning is kept")
    func phaseRejected() async throws {
        let transport = MockHTTPTransport([
            .openAIError(status: 400, code: "unknown_parameter", message: "Unknown parameter: 'input[1].phase'."),
            .stream(OpenAISSE.textResponse("ok")),
        ])
        let history: [LLMMessage] = [.user("hi"), LLMMessage(role: .assistant, content: [.text("Hello.")]), .user("again")]
        let request = LLMRequest(
            model: "gpt-6-luna", system: [SystemBlock("sys")], messages: history, effort: .low, provider: .openAI
        )
        let response = try await client(transport).complete(request)
        #expect(response.text == "ok")
        #expect(transport.requestCount == 2)

        let first = transport.body(ofRequest: 0)?["input"]?.arrayValue?[1]
        let second = transport.body(ofRequest: 1)?["input"]?.arrayValue?[1]
        #expect(first?["phase"] == "final_answer")
        #expect(second?["phase"] == nil)
        #expect(transport.body(ofRequest: 1)?["reasoning"] == ["effort": "low"], "only the setting the server named is dropped")
    }

    @Test("an unrelated 400 is not mistaken for a reasoning problem")
    func unrelatedBadRequest() async {
        let transport = MockHTTPTransport([.openAIError(status: 400, message: "Invalid schema for function 'x'")])
        await #expect(throws: LLMError.badRequest("Invalid schema for function 'x'")) { try await client(transport).complete(request()) }
        #expect(transport.requestCount == 1)
    }

    // MARK: Cancellation and addresses

    @Test("cancelling the caller stops the request and releases the connection")
    func cancellation() async {
        let transport = MockHTTPTransport([
            MockHTTPTransport.Response(
                chunks: SSE.chunked(OpenAISSE.created() + OpenAISSE.message(pieces: ["so far"]), size: 40), holdOpen: true
            )
        ])
        let task = Task { try await client(transport).complete(request()) }
        _ = await waitUntil { transport.requestCount == 1 }
        task.cancel()
        #expect(await waitUntil { transport.terminatedStreams == 1 })
        #expect(transport.requestCount == 1)
    }

    @Test("the key can only go to https hosts or the loopback interface", arguments: [
        ("https://api.openai.com/v1", true), ("https://gateway.example.com/v1", true), ("http://127.0.0.1:8080/v1", true),
        ("http://localhost:9999", true), ("http://evil.example.com/v1", false), ("ftp://x.test", false), ("file:///tmp/x", false),
    ])
    func acceptableAddresses(text: String, acceptable: Bool) throws {
        #expect(OpenAIClient.isAcceptable(try #require(URL(string: text))) == acceptable)
    }

    @Test("an unacceptable address falls back to OpenAI's own instead of leaking the key")
    func unsafeAddress() async throws {
        let transport = MockHTTPTransport([.stream(OpenAISSE.textResponse("ok")), .stream(OpenAISSE.textResponse("ok"))])
        _ = try await client(transport, baseURL: URL(string: "http://evil.example.com/v1")!).complete(request())
        #expect(transport.requests.first?.url?.host == "api.openai.com")

        _ = try await client(transport).complete(request(endpoint: URL(string: "http://evil.example.com/v1")!))
        #expect(transport.requests.last?.url?.host == "api.openai.com", "the address from Settings gets the same vetting")
    }

    @Test("an address from Settings is used when it is acceptable")
    func endpointFromSettings() async throws {
        let transport = MockHTTPTransport([.stream(OpenAISSE.textResponse("ok"))])
        _ = try await client(transport).complete(request(endpoint: URL(string: "https://gateway.example.com/v1")!))
        #expect(transport.requests.first?.url?.absoluteString == "https://gateway.example.com/v1/responses")
    }
}
