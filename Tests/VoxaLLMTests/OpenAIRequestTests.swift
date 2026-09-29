import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("OpenAI request")
struct OpenAIRequestTests {
    private let builder = OpenAIRequestBuilder(baseURL: OpenAIClient.officialBaseURL)

    private func tool(_ name: String) -> ToolDefinition {
        ToolDefinition(name: name, description: "Does \(name).", inputSchema: Schema.object(["x": Schema.string("An x")], required: ["x"]))
    }

    private func request(
        model: String = "gpt-6-luna",
        tools: [ToolDefinition]? = nil,
        messages: [LLMMessage]? = nil,
        effort: ReasoningEffort? = .medium
    ) -> LLMRequest {
        LLMRequest(
            model: model,
            system: [SystemBlock("You are Voxa."), SystemBlock("Second block.")],
            messages: messages ?? [.user("open safari")],
            tools: tools ?? [tool("open_url"), tool("open_app")],
            effort: effort,
            provider: .openAI
        )
    }

    // MARK: Parameters

    @Test("the request is stateless and streamed, with the system prompt as instructions")
    func shape() {
        let body = builder.body(for: request(), includeReasoning: true)
        #expect(body["model"] == "gpt-6-luna")
        #expect(body["stream"] == true)
        #expect(body["store"] == false, "nothing is kept on OpenAI's side for later retrieval")
        #expect(body["max_output_tokens"] == 16_000)
        #expect(body["instructions"] == "You are Voxa.\n\nSecond block.")
        for absent in ["previous_response_id", "temperature", "tool_choice", "messages", "system", "max_tokens"] {
            #expect(body[absent] == nil, "\(absent) must not be sent")
        }
    }

    @Test("tools are functions with strict mode off, sorted by name")
    func tools() {
        let tools = builder.body(for: request(tools: [tool("b_tool"), tool("a_tool")]), includeReasoning: true)["tools"]?.arrayValue
        #expect(tools?.compactMap { $0["name"]?.stringValue } == ["a_tool", "b_tool"])
        let first = tools?.first
        #expect(first?["type"] == "function")
        #expect(first?["description"] == "Does a_tool.")
        #expect(first?["strict"] == false, "the Responses API turns strict on by default, which rejects optional arguments")
        #expect(first?["parameters"]?["type"] == "object")
        #expect(first?["parameters"]?["additionalProperties"] == false)
        #expect(first?["function"] == nil, "the Responses API has no nested `function` object")
    }

    @Test("reasoning effort is sent only for models that reason", arguments: [
        ("gpt-6-luna", true), ("gpt-6-sol", true), ("gpt-6-astra", true), ("gpt-5.6", true), ("gpt-5.6-sol", true), ("o3", true),
        ("o4-mini", true), ("GPT-6-Luna", true), ("gpt-4.1", false), ("gpt-4o", false), ("some-gateway-model", false),
    ])
    func reasoning(model: String, expected: Bool) {
        let body = builder.body(for: request(model: model), includeReasoning: true)
        #expect((body["reasoning"] != nil) == expected)
        if expected { #expect(body["reasoning"] == ["effort": "medium"]) }
    }

    @Test("each thinking setting maps to the API's effort names")
    func effortNames() {
        for (effort, name) in [(ReasoningEffort.low, "low"), (.medium, "medium"), (.high, "high")] {
            #expect(builder.body(for: request(effort: effort), includeReasoning: true)["reasoning"] == ["effort": .string(name)])
        }
        #expect(builder.body(for: request(effort: nil), includeReasoning: true)["reasoning"] == nil)
    }

    @Test("reasoning can be left out, for a model that turns out not to take it")
    func reasoningOptOut() {
        #expect(builder.body(for: request(), includeReasoning: false)["reasoning"] == nil)
    }

    // MARK: Conversation

    @Test("a plain command is a user message")
    func userMessage() {
        let items = builder.body(for: request(), includeReasoning: false)["input"]?.arrayValue
        #expect(items == [["role": "user", "content": "open safari"]])
    }

    @Test("a tool round trip becomes a function call and its output, linked by call id")
    func toolRoundTrip() {
        let messages: [LLMMessage] = [
            .user("open safari"),
            LLMMessage(
                role: .assistant,
                content: [.text("Opening it."), .toolUse(id: "call_9", name: "open_app", input: ["name": "Safari"])]
            ),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: "call_9", content: [.text("Opened Safari.")], isError: false)]),
        ]
        let items = builder.body(for: request(messages: messages), includeReasoning: false)["input"]?.arrayValue
        #expect(items == [
            ["role": "user", "content": "open safari"],
            ["role": "assistant", "content": "Opening it.", "phase": "commentary"],
            ["type": "function_call", "call_id": "call_9", "name": "open_app", "arguments": #"{"name":"Safari"}"#],
            ["type": "function_call_output", "call_id": "call_9", "output": "Opened Safari."],
        ])
        // No item ids: they would tie the call to reasoning that isn't being replayed.
        #expect(items?[2]["id"] == nil)
    }

    @Test("a failed tool result says so in words, because the API has no error flag")
    func errorResult() {
        let output = OpenAIRequestBuilder.functionCallOutput(id: "c", parts: [.text("Nothing was run.")], isError: true)
        #expect(output["output"] == "Error: Nothing was run.")
        let ok = OpenAIRequestBuilder.functionCallOutput(id: "c", parts: [.text("Done.")], isError: false)
        #expect(ok["output"] == "Done.")
    }

    @Test("a tool result with an image carries it as an input_image")
    func imageResult() {
        let output = OpenAIRequestBuilder.functionCallOutput(
            id: "c", parts: [.text("Screenshot"), .image(mediaType: "image/png", base64: "AAAA")], isError: false
        )
        #expect(output["output"] == [
            ["type": "input_text", "text": "Screenshot"],
            ["type": "input_image", "image_url": "data:image/png;base64,AAAA"],
        ])
    }

    @Test("several tool results from one turn stay in order, one output each")
    func parallelResults() {
        let messages: [LLMMessage] = [
            .user("do two things"),
            LLMMessage(role: .assistant, content: [
                .toolUse(id: "call_a", name: "open_app", input: ["name": "Notes"]),
                .toolUse(id: "call_b", name: "open_url", input: ["url": "https://example.com"]),
            ]),
            LLMMessage(role: .user, content: [
                .toolResult(toolUseID: "call_a", content: [.text("A")], isError: false),
                .toolResult(toolUseID: "call_b", content: [.text("B")], isError: true),
            ]),
        ]
        let items = builder.body(for: request(messages: messages), includeReasoning: false)["input"]?.arrayValue ?? []
        #expect(items.compactMap { $0["call_id"]?.stringValue } == ["call_a", "call_b", "call_a", "call_b"])
        #expect(items.compactMap { $0["output"]?.stringValue } == ["A", "Error: B"])
    }

    @Test("blocks that belong to another provider are left out")
    func foreignBlocks() {
        let messages: [LLMMessage] = [
            .user("hi"),
            LLMMessage(role: .assistant, content: [.raw(["type": "thinking", "thinking": "hmm", "signature": "s"]), .text("Hello.")]),
            LLMMessage(role: .assistant, content: [.raw(["type": "fallback"])]),
        ]
        let items = builder.body(for: request(messages: messages), includeReasoning: false)["input"]?.arrayValue
        #expect(
            items == [["role": "user", "content": "hi"], ["role": "assistant", "content": "Hello.", "phase": "final_answer"]]
        )
    }

    // MARK: Message phase

    @Test("words before a tool call are sent back as commentary, and a turn's closing answer as the final answer")
    func phases() {
        let messages: [LLMMessage] = [
            .user("open safari"),
            LLMMessage(role: .assistant, content: [.text("On it."), .toolUse(id: "c1", name: "open_app", input: [:])]),
            LLMMessage(role: .user, content: [.toolResult(toolUseID: "c1", content: [.text("Opened.")], isError: false)]),
            LLMMessage(role: .assistant, content: [.text("Safari is open.")]),
            .user("thanks"),
        ]
        let items = builder.body(for: request(messages: messages), includeReasoning: false)["input"]?.arrayValue ?? []
        let phases = items.filter { $0["role"] == "assistant" }.map { $0["phase"]?.stringValue }
        #expect(phases == ["commentary", "final_answer"])
        #expect(items.filter { $0["role"] == "user" }.allSatisfy { $0["phase"] == nil }, "phase is never put on the user's words")
    }

    @Test("phase goes only to the models that use it", arguments: [
        ("gpt-6-luna", true), ("gpt-6-sol", true), ("GPT-6-Luna", true), ("gpt-7", true), ("gpt-5.6", true), ("gpt-5.6-sol", true),
        ("gpt-5.3-codex", true), ("gpt-5.4", true), ("gpt-5.2", false), ("gpt-5.1", false), ("gpt-5", false),
        ("gpt-5-mini", false), ("gpt-4.1", false), ("gpt-4o", false), ("o3", false), ("o4-mini", false), ("some-gateway-model", false),
    ])
    func phaseByModel(model: String, expected: Bool) {
        #expect(OpenAICapabilities.forModel(model).usesMessagePhase == expected)
        let messages: [LLMMessage] = [.user("hi"), LLMMessage(role: .assistant, content: [.text("Hello.")])]
        let items = builder.body(for: request(model: model, messages: messages), includeReasoning: false)["input"]?.arrayValue
        #expect((items?.last?["phase"] != nil) == expected)
    }

    @Test("phase can be left out, for a server that turns out not to know it")
    func phaseOptOut() {
        let messages: [LLMMessage] = [.user("hi"), LLMMessage(role: .assistant, content: [.text("Hello.")])]
        let items = builder.body(for: request(messages: messages), includeReasoning: false, includePhase: false)["input"]?.arrayValue
        #expect(items?.last == ["role": "assistant", "content": "Hello."])
    }

    // MARK: Wire

    @Test("headers: JSON in, event stream out, the key only as a bearer token")
    func headers() throws {
        let urlRequest = try builder.urlRequest(for: request(), apiKey: "sk-secret", includeReasoning: true)
        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "accept") == "text/event-stream")
        #expect(urlRequest.value(forHTTPHeaderField: "authorization") == "Bearer sk-secret")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == nil)
        let bodyText = String(data: try #require(urlRequest.httpBody), encoding: .utf8) ?? ""
        #expect(!bodyText.contains("sk-secret"), "the key must never appear in the body")
    }

    @Test("a custom address is used as given, with the path appended")
    func customAddress() throws {
        let custom = OpenAIRequestBuilder(baseURL: URL(string: "https://gateway.example.com/openai/v1")!)
        let urlRequest = try custom.urlRequest(for: request(), apiKey: "k", includeReasoning: false)
        #expect(urlRequest.url?.absoluteString == "https://gateway.example.com/openai/v1/responses")
    }

    @Test("encoding is deterministic byte for byte, so identical prefixes cache")
    func deterministic() throws {
        let first = try builder.urlRequest(for: request(), apiKey: "k", includeReasoning: true).httpBody
        let second = try builder.urlRequest(for: request(), apiKey: "k", includeReasoning: true).httpBody
        #expect(first == second)
    }
}
