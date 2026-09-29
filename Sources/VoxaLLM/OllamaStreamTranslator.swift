import Foundation
import VoxaCore

/// Turns Ollama's streamed chat lines into Voxa's provider-neutral `LLMStreamEvent`s.
///
/// Each line is a JSON object with a piece of the assistant message: some `content`, some `thinking` (not surfaced), or
/// `tool_calls`; the last line has `done: true` with token counts. Ollama's tool calls have **no ids** and arrive whole (the
/// arguments already an object), so an id is made up for each; it only has to be unique within the conversation.
struct OllamaChatTranslator: JSONLineTranslating {
    private(set) var isComplete = false

    private var started = false
    private var nextBlock = 0
    private var textBlock: Int?
    private var sawCall = false
    private let makeID: @Sendable () -> String

    init(makeID: @escaping @Sendable () -> String = { "call_" + UUID().uuidString.prefix(8).lowercased() }) {
        self.makeID = makeID
    }

    mutating func translate(_ json: JSONValue) throws -> [LLMStreamEvent] {
        // An error can arrive as a line of its own, mid-stream (the runner crashed, the model was unloaded).
        if let message = json["error"]?.stringValue {
            throw LLMError.stream(type: "ollama_error", message: message)
        }

        var events = begin(model: json["model"]?.stringValue)
        if let message = json["message"] {
            if let text = message["content"]?.stringValue, !text.isEmpty { events += textDelta(text) }
            for call in message["tool_calls"]?.arrayValue ?? [] { events += toolCall(call) }
        }
        if json["done"]?.boolValue == true { events += finish(json) }
        return events
    }

    private mutating func begin(model: String?) -> [LLMStreamEvent] {
        guard !started else { return [] }
        started = true
        return [.messageStart(id: "", model: model ?? "", usage: nil)]
    }

    private mutating func textDelta(_ text: String) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        let block: Int
        if let existing = textBlock {
            block = existing
        } else {
            block = nextBlock
            nextBlock += 1
            textBlock = block
            events.append(.blockStart(index: block, block: .text("")))
        }
        events.append(.blockDelta(index: block, delta: .text(text)))
        return events
    }

    private mutating func toolCall(_ call: JSONValue) -> [LLMStreamEvent] {
        guard let function = call["function"], let name = function["name"]?.stringValue, !name.isEmpty else { return [] }
        let block = nextBlock
        nextBlock += 1
        sawCall = true

        // The arguments are an object in the native API; some builds send the JSON as a string, as OpenAI does.
        let arguments: String
        switch function["arguments"] {
        case .object(let object)?: arguments = JSONValue.object(object).serialized()
        case .string(let text)?: arguments = text
        default: arguments = "{}"
        }
        // Ollama gives calls no id; a made-up one lets the result be matched to its call.
        let serverID = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return [
            .blockStart(index: block, block: .toolUse(id: serverID ?? makeID(), name: name)),
            .blockDelta(index: block, delta: .inputJSON(arguments)),
            .blockStop(index: block),
        ]
    }

    private mutating func finish(_ json: JSONValue) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        if let block = textBlock { events.append(.blockStop(index: block)) }

        let stopReason: StopReason
        if sawCall {
            stopReason = .toolUse
        } else {
            switch json["done_reason"]?.stringValue {
            case "length": stopReason = .maxTokens
            default: stopReason = .endTurn
            }
        }

        let prompt = json["prompt_eval_count"]?.intValue ?? 0
        let cached = json["prompt_eval_cached_count"]?.intValue ?? 0
        let usage = Usage(
            inputTokens: max(prompt - cached, 0),
            outputTokens: json["eval_count"]?.intValue ?? 0,
            cacheReadInputTokens: cached,
            cacheCreationInputTokens: 0
        )
        events.append(.messageDelta(stopReason: stopReason, usage: usage))
        events.append(.messageStop)
        isComplete = true
        return events
    }
}
