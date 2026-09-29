import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("AnthropicEventDecoder")
struct EventDecoderTests {
    private func decode(_ json: String) throws -> LLMStreamEvent? {
        try AnthropicEventDecoder.decode(SSEEvent(data: json))
    }

    @Test("message_start carries the id, model and input usage")
    func messageStart() throws {
        let event = try decode(
            // swiftlint:disable:next line_length
            #"{"type":"message_start","message":{"id":"msg_9","model":"claude-sonnet-5-5","usage":{"input_tokens":42,"output_tokens":1,"cache_read_input_tokens":40}}}"#
        )
        guard case .messageStart(let id, let model, let usage)? = event else {
            Issue.record("wrong event \(String(describing: event))")
            return
        }
        #expect(id == "msg_9")
        #expect(model == "claude-sonnet-5-5")
        #expect(usage == Usage(inputTokens: 42, outputTokens: 1, cacheReadInputTokens: 40))
    }

    @Test("block start distinguishes text, tool use, thinking and everything else")
    func blockStarts() throws {
        #expect(
            try decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
                == .blockStart(index: 0, block: .text(""))
        )
        #expect(
            try decode(
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"open_app","input":{}}}"#
            )
                == .blockStart(index: 1, block: .toolUse(id: "toolu_1", name: "open_app"))
        )
        #expect(
            try decode(
                #"{"type":"content_block_start","index":2,"content_block":{"type":"thinking","thinking":"","signature":""}}"#
            )
                == .blockStart(index: 2, block: .thinking)
        )
        let redacted: JSONValue = ["type": "redacted_thinking", "data": "abc"]
        #expect(
            try decode(
                #"{"type":"content_block_start","index":3,"content_block":{"type":"redacted_thinking","data":"abc"}}"#
            )
                == .blockStart(index: 3, block: .other(redacted))
        )
    }

    @Test("every delta kind is decoded, and an unknown one is tolerated")
    func deltas() throws {
        func delta(_ payload: String) throws -> LLMStreamEvent? {
            try decode(#"{"type":"content_block_delta","index":0,"delta":\#(payload)}"#)
        }
        #expect(try delta(#"{"type":"text_delta","text":"hi"}"#) == .blockDelta(index: 0, delta: .text("hi")))
        #expect(
            try delta(#"{"type":"input_json_delta","partial_json":"{\"a\":"}"#)
                == .blockDelta(index: 0, delta: .inputJSON(#"{"a":"#))
        )
        #expect(
            try delta(#"{"type":"thinking_delta","thinking":"hmm"}"#) == .blockDelta(index: 0, delta: .thinking("hmm"))
        )
        #expect(
            try delta(#"{"type":"signature_delta","signature":"sig"}"#)
                == .blockDelta(index: 0, delta: .signature("sig"))
        )
        #expect(try delta(#"{"type":"citations_delta","citation":{}}"#) == .blockDelta(index: 0, delta: .unknown))
    }

    @Test("message_delta carries the stop reason, including a refusal's category")
    func messageDelta() throws {
        #expect(
            try decode(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#)
                == .messageDelta(stopReason: .toolUse, usage: Usage(outputTokens: 30))
        )
        #expect(
            try decode(
                // swiftlint:disable:next line_length
                #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"}},"usage":{"output_tokens":0}}"#
            )
                == .messageDelta(stopReason: .refusal(category: "cyber"), usage: Usage())
        )
        #expect(
            try decode(
                #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":null},"usage":{"output_tokens":0}}"#
            )
                == .messageDelta(stopReason: .refusal(category: nil), usage: Usage())
        )
    }

    @Test("stop reasons map, and an unknown one is preserved")
    func stopReasons() {
        #expect(StopReason(wire: "end_turn") == .endTurn)
        #expect(StopReason(wire: "max_tokens") == .maxTokens)
        #expect(StopReason(wire: "pause_turn") == .pauseTurn)
        #expect(StopReason(wire: "brand_new") == .other("brand_new"))
    }

    @Test("stop, ping and unknown events")
    func simpleEvents() throws {
        #expect(try decode(#"{"type":"message_stop"}"#) == .messageStop)
        #expect(try decode(#"{"type":"ping"}"#) == .ping)
        #expect(try decode(#"{"type":"some_future_event","x":1}"#) == nil)
        #expect(try decode(#"{"no_type":true}"#) == nil)
    }

    @Test("an error event becomes a stream error carrying its type and message")
    func errorEvent() {
        do {
            _ = try decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
            Issue.record("expected an error")
        } catch let error as LLMError {
            #expect(error == .stream(type: "overloaded_error", message: "Overloaded"))
            #expect(error.isRetryable)
        } catch {
            Issue.record("wrong error \(error)")
        }
    }

    @Test(
        "malformed events are errors, not silently dropped",
        arguments: [
            "not json",
            #"{"type":"content_block_start"}"#,
            #"{"type":"content_block_delta","index":0}"#,
            #"{"type":"content_block_stop"}"#,
            #"{"type":"message_start"}"#,
        ]
    )
    func malformed(json: String) {
        #expect(throws: LLMError.self) { try decode(json) }
    }

    @Test("empty data is ignored")
    func emptyData() throws {
        #expect(try AnthropicEventDecoder.decode(SSEEvent(data: "")) == nil)
    }
}
