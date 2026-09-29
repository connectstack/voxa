import Foundation
import Testing
import VoxaCore
@testable import VoxaLLM
import VoxaTestSupport

private func assemble(_ text: String, chunkSize: Int = Int.max) throws -> (response: LLMResponse, complete: Bool) {
    let ids = OSAllocatedCounter()
    var decoder = JSONLineStreamDecoder(OllamaChatTranslator(makeID: { "call_\(ids.next())" }))
    var accumulator = MessageAccumulator()
    for chunk in SSE.chunked(text, size: chunkSize) {
        for event in try decoder.push(chunk) { try accumulator.apply(event) }
    }
    for event in try decoder.finish() { try accumulator.apply(event) }
    return (try accumulator.finish(), decoder.isComplete)
}

final class OSAllocatedCounter: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

@Suite("Ollama stream")
struct OllamaTranslatorTests {
    @Test("a text answer arrives whole, however the bytes are chunked", arguments: [1, 5, 64, 100_000])
    func text(chunkSize: Int) throws {
        let (response, complete) = try assemble(OllamaNDJSON.textResponse(["Hello ", "— café ", "😀."]), chunkSize: chunkSize)
        #expect(response.text == "Hello — café 😀.")
        #expect(response.stopReason == .endTurn)
        #expect(complete)
    }

    @Test("thinking is not shown")
    func thinkingHidden() throws {
        let stream = OllamaNDJSON.thinkingChunk("Let me consider…") + OllamaNDJSON.textChunk("Hi.") + OllamaNDJSON.done()
        #expect(try assemble(stream).response.text == "Hi.")
    }

    @Test("a tool call arrives whole, with an id made up for it")
    func toolCall() throws {
        let stream = OllamaNDJSON.toolCallResponse(name: "open_app", arguments: ["name": "Safari"])
        let (response, _) = try assemble(stream)
        #expect(response.stopReason == .toolUse)
        #expect(response.executableToolUses.count == 1)
        #expect(response.executableToolUses.first?.id == "call_1")
        #expect(response.executableToolUses.first?.name == "open_app")
        #expect(response.executableToolUses.first?.input == ["name": "Safari"])
    }

    @Test("text before a call, and several calls in one turn, keep their order and get distinct ids")
    func mixedTurn() throws {
        let stream = OllamaNDJSON.textChunk("Doing both. ")
            + OllamaNDJSON.toolCallChunk(name: "open_app", arguments: ["name": "Notes"])
            + OllamaNDJSON.toolCallChunk(name: "open_url", arguments: ["url": "https://example.com"])
            + OllamaNDJSON.done()
        let (response, _) = try assemble(stream, chunkSize: 17)
        #expect(response.text == "Doing both. ")
        #expect(response.executableToolUses.map(\.name) == ["open_app", "open_url"])
        #expect(Set(response.executableToolUses.map(\.id)).count == 2)
    }

    @Test("two calls in one chunk are both found")
    func twoInOneChunk() throws {
        let chunk = OllamaNDJSON.line([
            "model": "m", "done": false,
            "message": ["role": "assistant", "content": "", "tool_calls": [
                ["function": ["name": "a", "arguments": [:]]], ["function": ["name": "b", "arguments": ["x": 1]]],
            ]],
        ])
        let (response, _) = try assemble(chunk + OllamaNDJSON.done())
        #expect(response.executableToolUses.map(\.name) == ["a", "b"])
        #expect(response.executableToolUses.last?.input == ["x": 1])
    }

    @Test("arguments sent as a JSON string, an id from the server, and missing arguments are all handled")
    func argumentForms() throws {
        let asString = OllamaNDJSON.line([
            "model": "m", "done": false,
            "message": [
                "role": "assistant", "content": "",
                "tool_calls": [["id": "call_xyz", "function": ["name": "a", "arguments": #"{"k":"v"}"#]]],
            ],
        ]) + OllamaNDJSON.done()
        let response = try assemble(asString).response
        #expect(response.executableToolUses.first?.input == ["k": "v"])
        #expect(response.executableToolUses.first?.id == "call_xyz")

        let missing = OllamaNDJSON.line([
            "model": "m", "done": false, "message": ["role": "assistant", "content": "", "tool_calls": [["function": ["name": "a"]]]],
        ]) + OllamaNDJSON.done()
        #expect(try assemble(missing).response.executableToolUses.first?.input == JSONValue.object([:]))
    }

    @Test("a tool call with no name is ignored")
    func nameless() throws {
        let chunk = OllamaNDJSON.line([
            "model": "m", "done": false, "message": ["role": "assistant", "content": "", "tool_calls": [["function": ["arguments": [:]]]]],
        ])
        #expect(try assemble(chunk + OllamaNDJSON.textChunk("ok") + OllamaNDJSON.done()).response.executableToolUses.isEmpty)
    }

    @Test("token counts and the length limit are reported")
    func usageAndLength() throws {
        let stream = OllamaNDJSON.textChunk("cut") + OllamaNDJSON.done(reason: "length", promptTokens: 500, outputTokens: 77)
        let response = try assemble(stream).response
        #expect(response.stopReason == .maxTokens)
        #expect(response.usage.inputTokens == 500)
        #expect(response.usage.outputTokens == 77)
    }

    @Test("an error line mid-stream is an error that isn't retried")
    func errorLine() {
        let stream = OllamaNDJSON.textChunk("start") + OllamaNDJSON.errorLine("llama runner process has terminated: signal: killed")
        do {
            _ = try assemble(stream)
            Issue.record("expected an error")
        } catch let error as LLMError {
            #expect(!error.isRetryable)
            if case .stream(_, let message) = error { #expect(message.contains("runner process")) } else { Issue.record("\(error)") }
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test("a stream that just stops is not complete")
    func incomplete() throws {
        var decoder = JSONLineStreamDecoder(OllamaChatTranslator())
        _ = try decoder.push(Data(OllamaNDJSON.textChunk("half").utf8))
        _ = try decoder.finish()
        #expect(!decoder.isComplete)
    }

    @Test("blank lines are skipped and unreadable ones are an error")
    func blankAndBroken() throws {
        #expect(try assemble("\n\n" + OllamaNDJSON.textResponse(["ok"])).response.text == "ok")
        #expect(throws: LLMError.self) { _ = try assemble("{not json}\n") }
    }

    @Test("a final line without a newline is still read")
    func noTrailingNewline() throws {
        let stream = OllamaNDJSON.textChunk("hi") + String(OllamaNDJSON.done().dropLast())
        let (response, complete) = try assemble(stream)
        #expect(response.text == "hi" && complete)
    }
}
