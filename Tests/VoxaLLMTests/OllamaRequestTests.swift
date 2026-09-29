import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("Ollama request")
struct OllamaRequestTests {
    private let builder = OllamaRequestBuilder(baseURL: URL(string: "http://localhost:11434")!)

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "Does \(name).", inputSchema: Schema.object(["x": Schema.string("An x")], required: ["x"]))
    }

    private func request(
        tools: [ToolDefinition]? = nil, messages: [LLMMessage]? = nil, contextLength: Int? = nil, maxTokens: Int = 16_000
    ) -> LLMRequest {
        LLMRequest(
            model: "qwen3:8b",
            maxTokens: maxTokens,
            system: [SystemBlock("You are Voxa."), SystemBlock("Second.")],
            messages: messages ?? [.user("open safari")],
            tools: tools ?? [tool("open_url"), tool("open_app")],
            effort: .medium,
            provider: .ollama,
            contextLength: contextLength
        )
    }

    // MARK: Parameters

    @Test("the request is streamed, keeps the model loaded, and asks for a context window that fits Voxa's prompt")
    func shape() {
        let body = builder.body(for: request(), think: nil)
        #expect(body["model"] == "qwen3:8b")
        #expect(body["stream"] == true)
        #expect(body["keep_alive"] == "30m")
        #expect(body["options"]?["num_ctx"] == 16_384, "Ollama's own default would silently cut the prompt off")
        #expect(body["think"] == nil)
        #expect(body["options"]?["temperature"] == nil, "the model's own sampling defaults are left alone")
    }

    @Test("the configured context window is used, and generation is capped")
    func options() {
        let body = builder.body(for: request(contextLength: 32_768, maxTokens: 16_000), think: nil)
        #expect(body["options"]?["num_ctx"] == 32_768)
        #expect(body["options"]?["num_predict"] == 4_096)
        #expect(builder.body(for: request(maxTokens: 1_000), think: nil)["options"]?["num_predict"] == 1_000)
    }

    @Test("tools are functions under a `function` key, sorted by name")
    func tools() {
        let tools = builder.body(for: request(tools: [tool("b_tool"), tool("a_tool")]), think: nil)["tools"]?.arrayValue
        #expect(tools?.compactMap { $0["function"]?["name"]?.stringValue } == ["a_tool", "b_tool"])
        let first = tools?.first
        #expect(first?["type"] == "function")
        #expect(first?["function"]?["description"] == "Does a_tool.")
        #expect(first?["function"]?["parameters"]?["type"] == "object")
    }

    @Test("a request with no tools sends none")
    func noTools() {
        #expect(builder.body(for: request(tools: []), think: nil)["tools"] == nil)
    }

    @Test("the thinking setting is sent only when one was chosen")
    func think() {
        #expect(builder.body(for: request(), think: .off)["think"] == false)
        #expect(builder.body(for: request(), think: .level("low"))["think"] == "low")
    }

    // MARK: Conversation

    @Test("the system prompt is the first message")
    func system() {
        let messages = builder.body(for: request(), think: nil)["messages"]?.arrayValue
        #expect(messages?.first == ["role": "system", "content": "You are Voxa.\n\nSecond."])
        #expect(messages?.last == ["role": "user", "content": "open safari"])
    }

    @Test("a tool round trip: the call's arguments are an object, and the result names its tool")
    func toolRoundTrip() {
        let messages: [LLMMessage] = [
            .user("open safari"),
            LLMMessage(role: .assistant, content: [.text("On it."), .toolUse(id: "call_1", name: "open_app", input: ["name": "Safari"])]),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: "call_1", content: [.text("Opened Safari.")], isError: false)]),
        ]
        let sent = builder.body(for: request(messages: messages), think: nil)["messages"]?.arrayValue ?? []
        #expect(Array(sent.dropFirst()) == [
            ["role": "user", "content": "open safari"],
            ["role": "assistant", "content": "On it.", "tool_calls": [["function": ["name": "open_app", "arguments": ["name": "Safari"]]]]],
            ["role": "tool", "tool_name": "open_app", "content": "Opened Safari."],
        ])
    }

    @Test("an assistant turn that is only a tool call has empty content, not none")
    func callOnly() {
        let messages: [LLMMessage] = [
            .user("x"), LLMMessage(role: .assistant, content: [.toolUse(id: "c", name: "open_app", input: [:])]),
        ]
        let assistant = builder.body(for: request(messages: messages), think: nil)["messages"]?.arrayValue?.last
        #expect(assistant?["content"]?.stringValue?.isEmpty == true)
        #expect(assistant?["tool_calls"]?.arrayValue?.count == 1)
    }

    @Test("results from several calls in one turn come back in order, each with its own tool name")
    func parallelResults() {
        let messages: [LLMMessage] = [
            .user("two things"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "call_a", name: "open_app", input: ["name": "Notes"]),
                .toolUse(id: "call_b", name: "open_url", input: ["url": "https://example.com"]),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseID: "call_a", content: [.text("A")], isError: false),
                .toolResult(toolUseID: "call_b", content: [.text("B")], isError: true),
            ]),
        ]
        let sent = builder.body(for: request(messages: messages), think: nil)["messages"]?.arrayValue ?? []
        let tools = sent.filter { $0["role"] == "tool" }
        #expect(tools.compactMap { $0["tool_name"]?.stringValue } == ["open_app", "open_url"])
        #expect(tools.compactMap { $0["content"]?.stringValue } == ["A", "Error: B"])
    }

    @Test("an image a tool returned follows its result as a user message")
    func imageResult() {
        let messages: [LLMMessage] = [
            .user("look"),
            LLMMessage(role: .assistant, content: [.toolUse(id: "c", name: "screenshot", input: [:])]),
            LLMMessage(
                role: .user,
                content: [
                    .toolResult(
                        toolUseID: "c",
                        content: [.text("Captured"), .image(mediaType: "image/png", base64: "AAAA")],
                        isError: false
                    )
                ]
            ),
        ]
        let sent = builder.body(for: request(messages: messages), think: nil)["messages"]?.arrayValue ?? []
        let tail = Array(sent.suffix(2))
        #expect(tail.first == ["role": "tool", "tool_name": "screenshot", "content": "Captured"])
        #expect(tail.last?["role"] == "user")
        #expect(tail.last?["images"] == ["AAAA"])
    }

    @Test("blocks that belong to another provider are left out")
    func foreignBlocks() {
        let messages: [LLMMessage] = [
            .user("hi"),
            LLMMessage(
                role: .assistant,
                content: [.raw(["type": "thinking", "thinking": "hm", "signature": "s"]), .text("Hello.")]
            ),
        ]
        let sent = builder.body(for: request(messages: messages), think: nil)["messages"]?.arrayValue ?? []
        #expect(sent.last == ["role": "assistant", "content": "Hello."])
    }

    // MARK: Wire

    @Test("the request goes to /api/chat with no credentials")
    func wire() throws {
        let urlRequest = try builder.urlRequest(for: request(), think: nil)
        #expect(urlRequest.url?.absoluteString == "http://localhost:11434/api/chat")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "authorization") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("a server address is cleaned up, including an API path pasted along with it", arguments: [
        ("http://localhost:11434", "http://localhost:11434"), ("http://localhost:11434/", "http://localhost:11434"),
        ("http://localhost:11434/v1", "http://localhost:11434"), ("http://localhost:11434/v1/", "http://localhost:11434"),
        ("http://localhost:11434/api", "http://localhost:11434"), ("http://localhost:11434/api/chat", "http://localhost:11434"),
        ("https://ollama.example.com/base", "https://ollama.example.com/base"),
    ])
    func normalized(input: String, expected: String) throws {
        #expect(OllamaClient.normalized(try #require(URL(string: input))).absoluteString == expected)
    }
}
