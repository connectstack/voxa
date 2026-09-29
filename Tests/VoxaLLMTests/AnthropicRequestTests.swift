import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM

@Suite("ModelCapabilities")
struct ModelCapabilitiesTests {
    @Test(
        "effort is sent only to models documented to accept it",
        arguments: [
            ("claude-sonnet-5-5", true), ("claude-sonnet-5", true), ("claude-opus-5-5", true),
            ("claude-opus-4-8", true),
            ("claude-opus-4-6", true), ("claude-sonnet-4-6", true), ("claude-fable-5-1", true),
            ("claude-opus-4-5-20251101", true),
            ("claude-haiku-4-5", false), ("claude-haiku-4-5-20251001", false), ("claude-sonnet-4-5", false),
            ("some-proxy-model", false), ("", false),
        ]
    )
    func effort(model: String, expected: Bool) {
        #expect(ModelCapabilities.forModel(model).supportsEffort == expected)
    }

    @Test(
        "the refusal fallback is only for the models it is documented on",
        arguments: [
            ("claude-sonnet-5-5", true), ("claude-opus-5-5", true), ("claude-opus-5", true), ("claude-fable-5-1", true),
            ("claude-sonnet-5", false), ("claude-opus-4-8", false), ("claude-haiku-4-5", false), ("unknown", false),
        ]
    )
    func fallback(model: String, expected: Bool) {
        #expect(ModelCapabilities.forModel(model).supportsRefusalFallback == expected)
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(ModelCapabilities.forModel("Claude-Sonnet-5-5").supportsEffort)
    }
}

@Suite("AnthropicRequestBuilder")
struct AnthropicRequestBuilderTests {
    private let official = AnthropicRequestBuilder(baseURL: AnthropicClient.officialBaseURL)

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(
            name: name,
            description: "Does \(name).",
            inputSchema: Schema.object(["x": Schema.string("An x")], required: ["x"])
        )
    }

    private func request(
        model: String = "claude-sonnet-5-5",
        tools: [ToolDefinition]? = nil,
        messages: [LLMMessage]? = nil,
        effort: ReasoningEffort? = .medium,
        fallback: Bool = false
    ) -> LLMRequest {
        LLMRequest(
            model: model,
            system: [SystemBlock("You are Voxa.")],
            messages: messages ?? [.user("open safari")],
            tools: tools ?? [tool("open_url"), tool("open_app")],
            effort: effort,
            useRefusalFallback: fallback
        )
    }

    @Test("a Sonnet 5.5 request has exactly the parameters that model accepts")
    func sonnetShape() {
        let body = official.body(for: request(), useFallback: false)
        #expect(body["model"] == "claude-sonnet-5-5")
        #expect(body["stream"] == true)
        #expect(body["max_tokens"] == 16_000)
        #expect(body["output_config"] == ["effort": "medium"])
        // Parameters that 400 on this model (or that we deliberately never send).
        for forbidden in ["thinking", "temperature", "top_p", "top_k", "tool_choice", "fallbacks", "budget_tokens"] {
            #expect(body[forbidden] == nil, "\(forbidden) must not be sent")
        }
    }

    @Test("a model without effort support gets no output_config, and an unknown model gets the minimal request")
    func minimalForOthers() {
        for model in ["claude-haiku-4-5", "my-gateway-model"] {
            let body = official.body(for: request(model: model), useFallback: false)
            #expect(body["output_config"] == nil)
            #expect(body["thinking"] == nil)
        }
    }

    @Test("the system prompt is marked as a cache breakpoint, so tools and system are cached together")
    func systemCache() {
        let system = official.body(for: request(), useFallback: false)["system"]?.arrayValue
        #expect(system?.count == 1)
        #expect(system?.first?["cache_control"] == ["type": "ephemeral"])
        #expect(system?.first?["text"] == "You are Voxa.")
    }

    @Test("tools are sorted by name so the cached prefix doesn't depend on registration order")
    func toolOrder() throws {
        let one = try AnthropicRequestBuilder.encode(
            official.body(for: request(tools: [tool("b"), tool("a"), tool("c")]), useFallback: false)
        )
        let two = try AnthropicRequestBuilder.encode(
            official.body(for: request(tools: [tool("c"), tool("a"), tool("b")]), useFallback: false)
        )
        #expect(one == two)
        let names = official.body(for: request(tools: [tool("b"), tool("a")]), useFallback: false)["tools"]?.arrayValue?
            .compactMap { $0["name"]?.stringValue }
        #expect(names == ["a", "b"])
    }

    @Test("encoding is deterministic byte for byte")
    func deterministic() throws {
        let first = try AnthropicRequestBuilder.encode(official.body(for: request(), useFallback: false))
        let second = try AnthropicRequestBuilder.encode(official.body(for: request(), useFallback: false))
        #expect(first == second)
    }

    @Test("a tool schema is sent under input_schema, with its description")
    func toolWire() {
        let first = official.body(for: request(tools: [tool("open_app")]), useFallback: false)["tools"]?.arrayValue?
            .first
        #expect(first?["name"] == "open_app")
        #expect(first?["description"] == "Does open_app.")
        #expect(first?["input_schema"]?["type"] == "object")
        #expect(first?["input_schema"]?["additionalProperties"] == false)
    }

    @Test("the last block of the last message is a cache breakpoint, so each agent step reuses the previous steps")
    func rollingBreakpoint() {
        let messages: [LLMMessage] = [
            .user("open safari"),
            LLMMessage(role: .assistant, content: [.toolUse(id: "t1", name: "open_app", input: ["name": "Safari"])]),
            LLMMessage(
                role: .user,
                content: [.toolResult(toolUseID: "t1", content: [.text("Opened Safari")], isError: false)]
            ),
        ]
        let wire = official.body(for: request(messages: messages), useFallback: false)["messages"]?.arrayValue
        #expect(wire?.last?["content"]?.arrayValue?.last?["cache_control"] == ["type": "ephemeral"])
        #expect(wire?.first?["content"]?.arrayValue?.last?["cache_control"] == nil, "only the last message is marked")
    }

    @Test("a thinking block is never given a cache breakpoint")
    func noBreakpointOnRaw() {
        let messages: [LLMMessage] = [
            .user("hi"),
            LLMMessage(role: .assistant, content: [.raw(["type": "thinking", "thinking": "", "signature": "s"])]),
        ]
        let wire = official.body(for: request(messages: messages), useFallback: false)["messages"]?.arrayValue
        #expect(wire?.last?["content"]?.arrayValue?.last?["cache_control"] == nil)
    }

    @Test("tool results serialize with the id, content blocks and is_error only when set")
    func toolResultWire() {
        let ok = AnthropicRequestBuilder.wire(.toolResult(toolUseID: "t1", content: [.text("done")], isError: false))
        #expect(ok["type"] == "tool_result")
        #expect(ok["tool_use_id"] == "t1")
        #expect(ok["content"] == [["type": "text", "text": "done"]])
        #expect(ok["is_error"] == nil)

        let failed = AnthropicRequestBuilder.wire(.toolResult(toolUseID: "t2", content: [.text("nope")], isError: true))
        #expect(failed["is_error"] == true)

        let image = AnthropicRequestBuilder.wire(
            .toolResult(toolUseID: "t3", content: [.image(mediaType: "image/png", base64: "AAAA")], isError: false)
        )
        #expect(
            image["content"]?.arrayValue?.first?["source"] == [
                "type": "base64", "media_type": "image/png", "data": "AAAA",
            ]
        )
    }

    @Test("raw blocks are echoed exactly as received")
    func rawPassthrough() {
        let thinking: JSONValue = ["type": "thinking", "thinking": "x", "signature": "sig=="]
        #expect(AnthropicRequestBuilder.wire(.raw(thinking)) == thinking)
    }

    @Test("the fallback opt-in goes only to the official host and only for a supporting model")
    func fallbackGating() {
        #expect(official.allowsRefusalFallback(for: request(fallback: true)))
        #expect(!official.allowsRefusalFallback(for: request(fallback: false)))
        #expect(!official.allowsRefusalFallback(for: request(model: "claude-haiku-4-5", fallback: true)))
        let proxy = AnthropicRequestBuilder(baseURL: URL(string: "https://gateway.example.com")!)
        #expect(!proxy.allowsRefusalFallback(for: request(fallback: true)))
    }

    @Test("with the fallback on, the body and the beta header both carry it")
    func fallbackWire() throws {
        let urlRequest = try official.urlRequest(for: request(fallback: true), apiKey: "k", useFallback: true)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let body = try JSONValue.parse(try #require(urlRequest.httpBody))
        #expect(body["fallbacks"] == "default")

        let plain = try official.urlRequest(for: request(), apiKey: "k", useFallback: false)
        #expect(plain.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test("headers: JSON in, event stream out, the version, and the key only in x-api-key")
    func headers() throws {
        let urlRequest = try official.urlRequest(for: request(), apiKey: "sk-ant-secret", useFallback: false)
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant-secret")
        let bodyText = try String(data: #require(urlRequest.httpBody), encoding: .utf8) ?? ""
        #expect(!bodyText.contains("sk-ant-secret"), "the key must never appear in the body")
    }
}

@Suite("RetryPolicy")
struct RetryPolicyTests {
    private let policy = RetryPolicy(
        maxAttempts: 4,
        baseDelay: .milliseconds(500),
        maxDelay: .seconds(4),
        jitter: 0.2,
        maxRetryAfter: .seconds(10)
    )

    @Test("delays double each attempt and stop at the cap")
    func exponential() {
        let delays = (1...5).map { policy.delay(afterAttempt: $0, retryAfter: nil, random: 0.5) }  // 0.5 = no jitter
        #expect(delays == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(4)])
    }

    @Test("jitter stays within ±20%")
    func jitter() {
        let low = policy.delay(afterAttempt: 2, retryAfter: nil, random: 0)
        let high = policy.delay(afterAttempt: 2, retryAfter: nil, random: 1)
        #expect(low == .milliseconds(800))
        #expect(high == .milliseconds(1200))
    }

    @Test("the server's retry-after is honored, but capped")
    func retryAfter() {
        #expect(policy.delay(afterAttempt: 1, retryAfter: .seconds(3), random: 0.9) == .seconds(3))
        #expect(policy.delay(afterAttempt: 1, retryAfter: .seconds(300), random: 0.9) == .seconds(10))
        #expect(policy.delay(afterAttempt: 1, retryAfter: .seconds(-5), random: 0.9) == .zero)
    }
}
