import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

/// Runs Responses API stream text through the real decoder and accumulator, the way the client does.
private func assemble(_ sse: String, chunkSize: Int = Int.max) throws -> (response: LLMResponse, complete: Bool) {
    var decoder = SSEStreamDecoder(OpenAIResponsesTranslator())
    var accumulator = MessageAccumulator()
    for chunk in SSE.chunked(sse, size: chunkSize) {
        for event in try decoder.push(chunk) { try accumulator.apply(event) }
    }
    for event in try decoder.finish() { try accumulator.apply(event) }
    return (try accumulator.finish(), decoder.isComplete)
}

@Suite("OpenAI stream")
struct OpenAITranslatorTests {
    @Test("a text answer arrives whole, however the bytes are chunked", arguments: [1, 5, 64, 100_000])
    func text(chunkSize: Int) throws {
        let (response, complete) = try assemble(OpenAISSE.textResponse("Hello — café 😀."), chunkSize: chunkSize)
        #expect(response.text == "Hello — café 😀.")
        #expect(response.stopReason == .endTurn)
        #expect(response.id == "resp_1")
        #expect(response.model == "gpt-6-luna")
        #expect(complete)
    }

    @Test("a tool call's arguments are put together from fragments")
    func toolCall() throws {
        let sse = OpenAISSE.created()
            + OpenAISSE.functionCall(callID: "call_7", name: "open_app", argumentPieces: [#"{"na"#, #"me": "Saf"#, #"ari"}"#])
            + OpenAISSE.completed()
        let (response, _) = try assemble(sse, chunkSize: 9)
        #expect(response.stopReason == .toolUse)
        #expect(response.executableToolUses.count == 1)
        #expect(response.executableToolUses.first?.id == "call_7", "the call id, not the item id, is what a result refers to")
        #expect(response.executableToolUses.first?.name == "open_app")
        #expect(response.executableToolUses.first?.input == ["name": "Safari"])
    }

    @Test("arguments given whole, in the added item or only in the done event, are used")
    func wholeArguments() throws {
        let inItem = OpenAISSE.created()
            + OpenAISSE.functionCall(name: "look_up", argumentPieces: [#"{"value":"x"}"#], announceArguments: true)
            + OpenAISSE.completed()
        #expect(try assemble(inItem).response.executableToolUses.first?.input == ["value": "x"])

        // Only `.done` carries the arguments: no delta events at all.
        var onlyDone = OpenAISSE.created()
        onlyDone += OpenAISSE.event("response.output_item.added", [
            "output_index": 0, "item": ["type": "function_call", "id": "fc", "call_id": "call_1", "name": "look_up", "arguments": ""],
        ])
        onlyDone += OpenAISSE.event(
            "response.function_call_arguments.done",
            ["output_index": 0, "item_id": "fc", "arguments": #"{"value":"y"}"#]
        )
        onlyDone += OpenAISSE.completed()
        #expect(try assemble(onlyDone).response.executableToolUses.first?.input == ["value": "y"])
    }

    @Test("text before a tool call, and several calls in one turn, keep their order and ids")
    func mixedTurn() throws {
        let sse = OpenAISSE.created()
            + OpenAISSE.reasoning(outputIndex: 0)
            + OpenAISSE.message(outputIndex: 1, pieces: ["Opening both."], phase: "commentary")
            + OpenAISSE.functionCall(
                outputIndex: 2, itemID: "fc_a", callID: "call_a", name: "open_app", argumentPieces: [#"{"name":"Notes"}"#]
            )
            + OpenAISSE.functionCall(outputIndex: 3, itemID: "fc_b", callID: "call_b", name: "open_url", argumentPieces: [#"{"url":"https://example.com"}"#])
            + OpenAISSE.completed()
        let (response, _) = try assemble(sse, chunkSize: 13)
        #expect(response.text == "Opening both.")
        #expect(response.executableToolUses.map(\.id) == ["call_a", "call_b"])
        #expect(response.executableToolUses.map(\.name) == ["open_app", "open_url"])
        #expect(response.stopReason == .toolUse)
    }

    @Test("hidden reasoning is not surfaced")
    func reasoningHidden() throws {
        let (response, _) = try assemble(OpenAISSE.textResponse("Hi."))
        #expect(!response.content.contains { if case .raw = $0 { true } else { false } })
    }

    @Test("a second message in one response starts a new paragraph")
    func twoMessages() throws {
        let sse = OpenAISSE.created()
            + OpenAISSE.message(outputIndex: 0, id: "m1", pieces: ["First."])
            + OpenAISSE.message(outputIndex: 1, id: "m2", pieces: ["Second."])
            + OpenAISSE.completed()
        #expect(try assemble(sse).response.text == "First.\n\nSecond.")
    }

    @Test("token counts are reported with cached input separate, as for Claude")
    func usage() throws {
        let sse = OpenAISSE.created() + OpenAISSE.message(pieces: ["ok"])
            + OpenAISSE.completed(inputTokens: 1_000, cachedTokens: 800, outputTokens: 50)
        let usage = try assemble(sse).response.usage
        #expect(usage.inputTokens == 200)
        #expect(usage.cacheReadInputTokens == 800)
        #expect(usage.outputTokens == 50)
    }

    @Test("stop reasons: out of tokens, filtered, and a refusal")
    func stopReasons() throws {
        let cut = OpenAISSE.created() + OpenAISSE.message(pieces: ["partial"]) + OpenAISSE.incomplete(reason: "max_output_tokens")
        #expect(try assemble(cut).response.stopReason == .maxTokens)

        let filtered = OpenAISSE.created() + OpenAISSE.incomplete(reason: "content_filter")
        #expect(try assemble(filtered).response.stopReason == .refusal(category: "content_filter"))

        let refused = OpenAISSE.created()
            + OpenAISSE.event("response.refusal.delta", ["output_index": 0, "content_index": 0, "delta": "I can't help with that."])
            + OpenAISSE.completed()
        #expect(try assemble(refused).response.stopReason == .refusal(category: nil))

        let strange = OpenAISSE.created() + OpenAISSE.incomplete(reason: "something_new")
        #expect(try assemble(strange).response.stopReason == .other("something_new"))
    }

    @Test("a tool call cut off by the token limit is reported as such, so it is never run")
    func truncatedCall() throws {
        let sse = OpenAISSE.created()
            + OpenAISSE.event("response.output_item.added", [
                "output_index": 0,
                "item": [
                    "type": "function_call", "id": "fc", "call_id": "call_1", "name": "run_applescript", "arguments": "",
                ],
            ])
            + OpenAISSE.event("response.function_call_arguments.delta", ["output_index": 0, "item_id": "fc", "delta": #"{"script": "tell"#])
            + OpenAISSE.incomplete(reason: "max_output_tokens")
        let (response, _) = try assemble(sse)
        #expect(response.stopReason == .maxTokens)
        #expect(response.malformedToolInputs["call_1"] != nil, "half a JSON object is never guessed at")
    }

    @Test("failures inside the stream become errors with the right retry behavior")
    func failures() throws {
        func error(_ sse: String) -> LLMError? {
            do {
                _ = try assemble(OpenAISSE.created() + sse)
                return nil
            } catch let error as LLMError {
                return error
            } catch {
                return nil
            }
        }
        #expect(error(OpenAISSE.failed(code: "server_error", message: "boom"))?.isRetryable == true)
        #expect(error(OpenAISSE.failed(code: "rate_limit_exceeded", message: "slow"))?.isRetryable == true)
        #expect(error(OpenAISSE.failed(code: "insufficient_quota", message: "no credit")) == .quotaExceeded("no credit"))
        #expect(error(OpenAISSE.error(code: "invalid_api_key", message: "bad key")) == .authentication("bad key"))
        #expect(error(OpenAISSE.error(code: "context_length_exceeded", message: "too long")) == .requestTooLarge)
        #expect(error(OpenAISSE.failed(code: "invalid_prompt", message: "nope")) != nil)
    }

    @Test("unknown events are ignored; unreadable ones are an error")
    func unknownAndBroken() throws {
        let sse = OpenAISSE.created() + OpenAISSE.event("response.something.brand_new", ["x": 1])
            + OpenAISSE.message(pieces: ["ok"]) + OpenAISSE.completed()
        #expect(try assemble(sse).response.text == "ok")

        #expect(throws: LLMError.self) { _ = try assemble("event: response.created\ndata: {not json\n\n") }
    }

    @Test("a stream that just stops is not complete")
    func incomplete() throws {
        var decoder = SSEStreamDecoder(OpenAIResponsesTranslator())
        _ = try decoder.push(Data((OpenAISSE.created() + OpenAISSE.message(pieces: ["half"])).utf8))
        _ = try decoder.finish()
        #expect(!decoder.isComplete)
    }

    @Test("events before response.created still get a message start first")
    func startsFirst() throws {
        var decoder = SSEStreamDecoder(OpenAIResponsesTranslator())
        let events = try decoder.push(Data(OpenAISSE.message(pieces: ["x"]).utf8))
        if case .messageStart? = events.first {} else { Issue.record("the first event was \(String(describing: events.first))") }
    }
}
