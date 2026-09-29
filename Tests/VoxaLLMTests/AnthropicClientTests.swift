import Foundation
import os
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("AnthropicClient")
@MainActor
struct AnthropicClientTests {
    private let noJitter = RetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(600),
        maxDelay: .seconds(8),
        jitter: 0,
        maxRetryAfter: .seconds(20)
    )

    private func client(
        _ transport: MockHTTPTransport,
        key: String? = "sk-ant-test",
        clock: ManualClock = ManualClock(),
        baseURL: URL = AnthropicClient.officialBaseURL
    ) -> AnthropicClient {
        AnthropicClient(
            keys: InMemoryAPIKeyStore(key: key),
            transport: transport,
            baseURL: baseURL,
            retryPolicy: noJitter,
            clock: clock
        )
    }

    private var request: LLMRequest {
        LLMRequest(
            model: "claude-sonnet-5-5",
            system: [SystemBlock("sys")],
            messages: [.user("hi")],
            effort: .medium,
            useRefusalFallback: true
        )
    }

    /// Lets the code under test reach its retry sleep, then moves the clock past it.
    private func release(_ clock: ManualClock, by duration: Duration) async {
        _ = await clock.waitForSleepers()
        clock.advance(by: duration)
    }

    // MARK: Success

    @Test("a complete answer streams through, however the bytes are chunked")
    func streams() async throws {
        for size in [1, 7, 64, 100_000] {
            let transport = MockHTTPTransport([.stream(SSE.textMessage("Hello — café 😀."), chunkSize: size)])
            let response = try await client(transport).complete(request)
            #expect(response.text == "Hello — café 😀.", "chunk size \(size)")
            #expect(response.stopReason == .endTurn)
        }
    }

    @Test("events are delivered as they arrive")
    func eventOrder() async throws {
        let transport = MockHTTPTransport([
            .stream(SSE.messageStart() + SSE.ping() + SSE.textBlock(["a", "b"]) + SSE.messageEnd())
        ])
        var kinds: [String] = []
        for try await event in client(transport).stream(request) {
            switch event {
            case .messageStart: kinds.append("start")
            case .ping: kinds.append("ping")
            case .blockStart: kinds.append("block")
            case .blockDelta: kinds.append("delta")
            case .blockStop: kinds.append("stop")
            case .messageDelta: kinds.append("mdelta")
            case .messageStop: kinds.append("end")
            case .restarted: kinds.append("restart")
            }
        }
        #expect(kinds == ["start", "ping", "block", "delta", "delta", "stop", "mdelta", "end"])
    }

    @Test("the request carries the key in a header, the effort and the fallback opt-in, and nothing secret in the body")
    func requestContents() async throws {
        let transport = MockHTTPTransport([.stream(SSE.textMessage("ok"))])
        _ = try await client(transport).complete(request)

        let sent = try #require(transport.requests.first)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = try #require(transport.body(ofRequest: 0))
        #expect(body["fallbacks"] == "default")
        #expect(body["output_config"] == ["effort": "medium"])
        #expect(String(data: try #require(sent.httpBody), encoding: .utf8)?.contains("sk-ant-test") == false)
    }

    // MARK: Errors that must not be retried

    @Test("without a key nothing is sent")
    func missingKey() async {
        let transport = MockHTTPTransport([])
        await #expect(throws: LLMError.missingAPIKey) { try await client(transport, key: nil).complete(request) }
        #expect(transport.requestCount == 0)
    }

    @Test(
        "client errors fail at once with a specific error",
        arguments: [
            (401, "authentication_error", "invalid x-api-key", LLMError.authentication("invalid x-api-key")),
            (403, "permission_error", "not allowed", LLMError.permissionDenied("not allowed")),
            (404, "not_found_error", "model: nope", LLMError.modelNotFound("model: nope")),
            (400, "invalid_request_error", "bad field", LLMError.badRequest("bad field")),
            (413, "request_too_large", "too big", LLMError.requestTooLarge),
        ]
    )
    func clientErrors(status: Int, type: String, message: String, expected: LLMError) async {
        let transport = MockHTTPTransport([.error(status: status, type: type, message: message)])
        await #expect(throws: expected) { try await client(transport).complete(request) }
        #expect(transport.requestCount == 1, "a \(status) must not be retried")
    }

    @Test("a mid-stream error that isn't transient is thrown immediately")
    func permanentStreamError() async {
        let sse = SSE.messageStart() + SSE.errorEvent(type: "invalid_request_error", message: "nope")
        let transport = MockHTTPTransport([.stream(sse)])
        await #expect(throws: LLMError.stream(type: "invalid_request_error", message: "nope")) {
            try await client(transport).complete(request)
        }
        #expect(transport.requestCount == 1)
    }

    @Test("no internet fails fast, without waiting through retries")
    func offline() async {
        let transport = MockHTTPTransport([Response(sendFailure: URLError(.notConnectedToInternet))])
        await #expect(throws: LLMError.offline) { try await client(transport).complete(request) }
        #expect(transport.requestCount == 1)
    }

    // MARK: Retries

    @Test("a 429 waits as long as retry-after says, then succeeds")
    func rateLimited() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .error(status: 429, type: "rate_limit_error", message: "slow down", headers: ["retry-after": "2"]),
            .stream(SSE.textMessage("ok")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request) }
        await release(clock, by: .seconds(2))
        #expect(try await task.value.text == "ok")
        #expect(transport.requestCount == 2)
    }

    @Test("overloaded responses back off exponentially and then succeed")
    func overloaded() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .error(status: 529, type: "overloaded_error", message: "Overloaded"),
            .error(status: 500, type: "api_error", message: "oops"),
            .stream(SSE.textMessage("finally")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request) }

        await release(clock, by: .milliseconds(600))  // first backoff
        #expect(await waitUntil { transport.requestCount == 2 })
        await release(clock, by: .milliseconds(1_200))  // second backoff is twice as long
        #expect(try await task.value.text == "finally")
        #expect(transport.requestCount == 3)
    }

    @Test("it gives up after the attempt limit and reports the last error")
    func givesUp() async {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .error(status: 529, type: "overloaded_error", message: "a"),
            .error(status: 529, type: "overloaded_error", message: "b"),
            .error(status: 529, type: "overloaded_error", message: "c"),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request) }
        await release(clock, by: .seconds(1))
        _ = await waitUntil { transport.requestCount == 2 }
        await release(clock, by: .seconds(2))
        await #expect(throws: LLMError.overloaded) { try await task.value }
        #expect(transport.requestCount == 3)
    }

    @Test("a stream that dies mid-answer is retried, and the consumer is told to discard the partial")
    func midStreamFailure() async throws {
        let clock = ManualClock()
        let partial =
            SSE.messageStart(id: "msg_old")
            + SSE.textBlock(["half of an ans"]).replacingOccurrences(
                of: "event: content_block_stop",
                with: "event: ping"
            )
        let transport = MockHTTPTransport([
            .stream(partial, then: URLError(.networkConnectionLost)),
            .stream(SSE.textMessage("the whole answer", id: "msg_new")),
        ])
        let restarts = OSAllocatedUnfairLock(initialState: 0)
        let task = Task { () -> LLMResponse in
            try await client(transport, clock: clock).complete(request) { event in
                if case .restarted = event { restarts.withLock { $0 += 1 } }
            }
        }
        await release(clock, by: .milliseconds(600))
        let response = try await task.value
        #expect(response.text == "the whole answer")
        #expect(response.id == "msg_new")
        #expect(restarts.withLock { $0 } == 1)
    }

    @Test("a transient error event inside a stream is retried")
    func transientStreamError() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .stream(SSE.messageStart() + SSE.errorEvent(type: "overloaded_error", message: "Overloaded")),
            .stream(SSE.textMessage("recovered")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request) }
        await release(clock, by: .milliseconds(600))
        #expect(try await task.value.text == "recovered")
    }

    @Test("a body that ends without message_stop counts as a dropped connection")
    func truncated() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([
            .stream(SSE.messageStart() + SSE.textBlock(["cut"])),
            .stream(SSE.textMessage("complete")),
        ])
        let task = Task { try await client(transport, clock: clock).complete(request) }
        await release(clock, by: .milliseconds(600))
        #expect(try await task.value.text == "complete")
    }

    @Test("a timeout is retried")
    func timeout() async throws {
        let clock = ManualClock()
        let transport = MockHTTPTransport([Response(sendFailure: URLError(.timedOut)), .stream(SSE.textMessage("ok"))])
        let task = Task { try await client(transport, clock: clock).complete(request) }
        await release(clock, by: .milliseconds(600))
        #expect(try await task.value.text == "ok")
    }

    // MARK: Fallback opt-in

    @Test("if the API rejects the fallback opt-in, the request is repeated without it")
    func fallbackRejected() async throws {
        let transport = MockHTTPTransport([
            .error(
                status: 400,
                type: "invalid_request_error",
                message: "Unexpected value(s) `server-side-fallback-2026-07-01` for the `anthropic-beta` header."
            ),
            .stream(SSE.textMessage("ok")),
        ])
        let response = try await client(transport).complete(request)
        #expect(response.text == "ok")
        #expect(transport.requestCount == 2)
        #expect(transport.requests[0].value(forHTTPHeaderField: "anthropic-beta") != nil)
        #expect(transport.requests[1].value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(transport.body(ofRequest: 1)?["fallbacks"] == nil)
    }

    @Test("an unrelated 400 is not mistaken for a fallback problem")
    func unrelatedBadRequest() async {
        let transport = MockHTTPTransport([
            .error(status: 400, type: "invalid_request_error", message: "messages: roles must alternate")
        ])
        await #expect(throws: LLMError.badRequest("messages: roles must alternate")) {
            try await client(transport).complete(request)
        }
        #expect(transport.requestCount == 1)
    }

    // MARK: Cancellation

    @Test("cancelling the caller stops the request and releases the connection")
    func cancellation() async {
        let transport = MockHTTPTransport([
            Response(chunks: SSE.chunked(SSE.messageStart() + SSE.textBlock(["so far"]), size: 40), holdOpen: true)
        ])
        let task = Task { try await client(transport).complete(request) }
        _ = await waitUntil { transport.requestCount == 1 }
        task.cancel()
        #expect(await waitUntil { transport.terminatedStreams == 1 }, "the body stream must be torn down")
        #expect(transport.requestCount == 1, "no retry after a cancel")
    }

    // MARK: Base URL safety

    @Test(
        "the key can only ever go to https hosts or the loopback interface",
        arguments: [
            ("https://api.anthropic.com", true), ("https://gateway.example.com", true), ("http://127.0.0.1:8080", true),
            ("http://localhost:9999", true), ("http://evil.example.com", false), ("ftp://x.test", false),
            ("file:///tmp/x", false),
        ]
    )
    func baseURL(text: String, acceptable: Bool) throws {
        #expect(AnthropicClient.isAcceptable(try #require(URL(string: text))) == acceptable)
    }

    @Test("an unacceptable base URL falls back to Anthropic's own endpoint instead of leaking the key")
    func unsafeBaseURL() async throws {
        let transport = MockHTTPTransport([.stream(SSE.textMessage("ok"))])
        _ = try await client(transport, baseURL: URL(string: "http://evil.example.com")!).complete(request)
        #expect(transport.requests.first?.url?.host == "api.anthropic.com")
    }
}

private typealias Response = MockHTTPTransport.Response
