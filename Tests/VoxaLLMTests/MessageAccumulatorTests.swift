import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

@Suite("MessageAccumulator")
struct MessageAccumulatorTests {
    /// Runs an SSE script through the real parser and decoder into an accumulator.
    private func assemble(_ sse: String) throws -> LLMResponse {
        var splitter = LineSplitter()
        var parser = SSEParser()
        var accumulator = MessageAccumulator()
        for line in splitter.push(Data(sse.utf8)) {
            if let event = parser.feed(line: line), let decoded = try AnthropicEventDecoder.decode(event) {
                try accumulator.apply(decoded)
            }
        }
        return try accumulator.finish()
    }

    @Test("a text answer is reassembled from its deltas")
    func text() throws {
        let response = try assemble(SSE.messageStart() + SSE.textBlock(["Hel", "lo ", "there."]) + SSE.messageEnd())
        #expect(response.text == "Hello there.")
        #expect(response.stopReason == .endTurn)
        #expect(response.id == "msg_01")
        #expect(response.usage.outputTokens == 12)
    }

    @Test("tool input arriving as JSON fragments, even split mid-string and mid-escape, parses at the end")
    func fragmentedToolInput() throws {
        let sse =
            SSE.messageStart()
            + SSE.toolUseBlock(
                id: "toolu_1",
                name: "open_url",
                jsonPieces: [#"{"url": "https://exa"#, #"mple.com/caf\u00"#, #"e9?q=1"}"#]
            )
            + SSE.messageEnd(stopReason: "tool_use")
        let response = try assemble(sse)
        let calls = response.executableToolUses
        #expect(calls.count == 1)
        #expect(calls[0].name == "open_url")
        #expect(calls[0].input["url"]?.stringValue == "https://example.com/café?q=1")
        #expect(response.stopReason == .toolUse)
        #expect(response.malformedToolInputs.isEmpty)
    }

    @Test("a tool call with no arguments has an empty object as its input")
    func emptyInput() throws {
        let response = try assemble(
            SSE.messageStart() + SSE.toolUseBlock(id: "toolu_1", name: "list_shortcuts", jsonPieces: [])
                + SSE.messageEnd(stopReason: "tool_use")
        )
        #expect(response.executableToolUses.first?.input == .object([:]))
    }

    @Test("tool input that isn't valid JSON is flagged, never guessed at")
    func malformedInput() throws {
        let sse =
            SSE.messageStart()
            + SSE.toolUseBlock(id: "toolu_bad", name: "open_url", jsonPieces: [#"{"url": "https://exa"#])  // cut off
            + SSE.toolUseBlock(index: 1, id: "toolu_arr", name: "open_url", jsonPieces: ["[1,2]"])  // not an object
            + SSE.messageEnd(stopReason: "tool_use")
        let response = try assemble(sse)
        #expect(Set(response.malformedToolInputs.keys) == ["toolu_bad", "toolu_arr"])
        #expect(response.malformedToolInputs["toolu_bad"] == #"{"url": "https://exa"#)
    }

    @Test("thinking blocks keep their text and signature exactly, for the next request")
    func thinking() throws {
        let response = try assemble(
            SSE.messageStart()
                + SSE.thinkingBlock(index: 0, text: "let me see", signature: "EqQBCkYI")
                + SSE.textBlock(index: 1, ["Done."]) + SSE.messageEnd()
        )
        let expected: JSONValue = ["type": "thinking", "thinking": "let me see", "signature": "EqQBCkYI"]
        #expect(response.content.first == .raw(expected))
        #expect(response.text == "Done.")
    }

    @Test("an omitted thinking summary (empty text) is still echoed with its signature")
    func omittedThinking() throws {
        let response = try assemble(
            SSE.messageStart() + SSE.thinkingBlock(signature: "sigOnly") + SSE.textBlock(index: 1, ["ok"])
                + SSE.messageEnd()
        )
        #expect(response.content.first == .raw(["type": "thinking", "thinking": "", "signature": "sigOnly"]))
    }

    @Test("unknown block types are preserved verbatim")
    func unknownBlocks() throws {
        let redacted: JSONValue = ["type": "redacted_thinking", "data": "opaque"]
        let response = try assemble(
            SSE.messageStart() + SSE.wholeBlock(index: 0, redacted) + SSE.textBlock(index: 1, ["hi"]) + SSE.messageEnd()
        )
        #expect(response.content.first == .raw(redacted))
    }

    @Test("an empty text block is dropped, because the API rejects one in a request")
    func emptyTextDropped() throws {
        let response = try assemble(
            SSE.messageStart() + SSE.textBlock(index: 0, [""])
                + SSE.toolUseBlock(index: 1, id: "t", name: "x", jsonPieces: ["{}"])
                + SSE.messageEnd(stopReason: "tool_use")
        )
        #expect(response.content.count == 1)
    }

    @Test("blocks come out in index order")
    func order() throws {
        let response = try assemble(
            SSE.messageStart() + SSE.textBlock(index: 0, ["first"])
                + SSE.toolUseBlock(index: 1, id: "t1", name: "a", jsonPieces: ["{}"])
                + SSE.toolUseBlock(index: 2, id: "t2", name: "b", jsonPieces: ["{}"])
                + SSE.messageEnd(stopReason: "tool_use")
        )
        #expect(response.executableToolUses.map(\.name) == ["a", "b"])
        #expect(response.content.first == .text("first"))
    }

    @Test("a refusal is reported with its category")
    func refusal() throws {
        let response = try assemble(SSE.messageStart() + SSE.messageEnd(stopReason: "refusal", category: "cyber"))
        #expect(response.stopReason == .refusal(category: "cyber"))
        #expect(response.content.isEmpty)
    }

    @Test("a stream that ends before message_stop is incomplete")
    func incomplete() {
        #expect(throws: LLMError.incompleteStream) {
            _ = try assemble(SSE.messageStart() + SSE.textBlock(["cut off"]))
        }
        #expect(throws: LLMError.incompleteStream) {
            _ = try MessageAccumulator().finish()
        }
    }

    @Test("a restart discards everything received so far")
    func restart() throws {
        var accumulator = MessageAccumulator()
        try accumulator.apply(.messageStart(id: "old", model: "m", usage: nil))
        try accumulator.apply(.blockStart(index: 0, block: .text("stale")))
        try accumulator.apply(.restarted(attempt: 2))
        try accumulator.apply(.messageStart(id: "new", model: "m", usage: nil))
        try accumulator.apply(.blockStart(index: 0, block: .text("fresh")))
        try accumulator.apply(.messageStop)
        let response = try accumulator.finish()
        #expect(response.id == "new")
        #expect(response.text == "fresh")
    }

    @Test("a delta for a block that never started is ignored")
    func strayDelta() throws {
        var accumulator = MessageAccumulator()
        try accumulator.apply(.messageStart(id: "m", model: "x", usage: nil))
        try accumulator.apply(.blockDelta(index: 9, delta: .text("orphan")))
        try accumulator.apply(.messageStop)
        #expect(try accumulator.finish().content.isEmpty)
    }
}

@Suite("Fallback boundaries")
struct FallbackTests {
    private let fallback: JSONValue = [
        "type": "fallback", "from": ["model": "claude-sonnet-5-5"], "to": ["model": "claude-opus-4-8"],
    ]

    @Test("a tool call in the declined partial output is never executable")
    func partialToolCallNotExecutable() {
        let response = LLMResponse(content: [
            .text("Sure, "),
            .toolUse(id: "toolu_declined", name: "run_applescript", input: ["script": "beep"]),
            .raw(fallback),
            .toolUse(id: "toolu_ok", name: "open_app", input: ["name": "Safari"]),
        ])
        #expect(response.executableToolUses.map(\.id) == ["toolu_ok"])
    }

    @Test("with no fallback marker every tool call is executable")
    func noMarker() {
        let response = LLMResponse(content: [
            .toolUse(id: "a", name: "x", input: [:]), .toolUse(id: "b", name: "y", input: [:]),
        ])
        #expect(response.executableToolUses.count == 2)
    }

    @Test("echoed history drops the declined partial's thinking and tool calls, keeps its text, and drops the marker")
    func historyEcho() {
        let response = LLMResponse(content: [
            .raw(["type": "thinking", "thinking": "", "signature": "s1"]),
            .text("Sure, "),
            .toolUse(id: "toolu_declined", name: "x", input: [:]),
            .raw(fallback),
            .raw(["type": "thinking", "thinking": "", "signature": "s2"]),
            .text("Here you go."),
        ])
        #expect(
            response.contentForHistory == [
                .text("Sure, "),
                .raw(["type": "thinking", "thinking": "", "signature": "s2"]),
                .text("Here you go."),
            ]
        )
    }

    @Test("without a marker the history echo is the content unchanged")
    func historyUnchanged() {
        let content: [ContentBlock] = [.raw(["type": "thinking", "thinking": "", "signature": "s"]), .text("hi")]
        #expect(LLMResponse(content: content).contentForHistory == content)
    }
}
