import Foundation
import VoxaCore

/// Turns the Responses API's streaming events into Voxa's provider-neutral `LLMStreamEvent`s.
///
/// The API describes a response as a list of *output items* (a message, a function call, hidden reasoning) and streams
/// changes to them. Voxa's events are a flat list of *blocks* (text, tool use). This assigns block numbers as items appear:
/// a message's text becomes a text block, and a `function_call` item becomes a tool-use block whose input arrives as the
/// argument fragments stream in. Reasoning items are not surfaced.
///
/// Event names and fields follow OpenAI's published API reference. Unknown event types are ignored so a new one can't break
/// the app; a malformed known one is an error.
struct OpenAIResponsesTranslator: SSETranslating {
    private struct TextKey: Hashable {
        var outputIndex: Int
        var contentIndex: Int
    }

    private struct CallState {
        var block: Int
        var receivedArguments: Bool
    }

    private(set) var isComplete = false

    private var started = false
    private var nextBlock = 0
    private var textBlocks: [TextKey: Int] = [:]
    private var calls: [Int: CallState] = [:]
    private var openBlocks: [Int] = []
    private var sawCall = false
    private var sawRefusal = false
    private var sawText = false

    mutating func translate(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        guard !event.data.isEmpty, event.data != "[DONE]" else { return [] }
        guard let json = try? JSONValue.parse(event.data) else { throw LLMError.invalidResponse("unreadable event") }
        let type = json["type"]?.stringValue ?? event.event ?? ""

        switch type {
        case "response.created":
            return begin(id: json["response"]?["id"]?.stringValue, model: json["response"]?["model"]?.stringValue)

        case "response.output_item.added":
            return begin() + itemAdded(json)

        case "response.output_text.delta":
            return begin() + textDelta(json)

        case "response.refusal.delta":
            sawRefusal = true
            return []

        case "response.function_call_arguments.delta":
            return argumentsDelta(json)

        case "response.function_call_arguments.done":
            return argumentsDone(json)

        case "response.output_item.done":
            return itemDone(json)

        case "response.completed":
            return begin() + finish(response: json["response"], incomplete: false)

        case "response.incomplete":
            return begin() + finish(response: json["response"], incomplete: true)

        case "response.failed":
            throw Self.failure(json["response"]?["error"])

        case "error":
            throw Self.failure(json)

        default:
            return []
        }
    }

    // MARK: Events

    private mutating func begin(id: String? = nil, model: String? = nil) -> [LLMStreamEvent] {
        guard !started else { return [] }
        started = true
        return [.messageStart(id: id ?? "", model: model ?? "", usage: nil)]
    }

    private mutating func allocateBlock() -> Int {
        defer { nextBlock += 1 }
        openBlocks.append(nextBlock)
        return nextBlock
    }

    private mutating func itemAdded(_ json: JSONValue) -> [LLMStreamEvent] {
        guard json["item"]?["type"]?.stringValue == "function_call", let item = json["item"] else { return [] }
        let outputIndex = json["output_index"]?.intValue ?? nextBlock
        let callID = item["call_id"]?.stringValue ?? item["id"]?.stringValue ?? "call_\(outputIndex)"
        let block = allocateBlock()
        sawCall = true

        let arguments = item["arguments"]?.stringValue ?? ""
        calls[outputIndex] = CallState(block: block, receivedArguments: !arguments.isEmpty)
        var events: [LLMStreamEvent] = [.blockStart(index: block, block: .toolUse(id: callID, name: item["name"]?.stringValue ?? ""))]
        if !arguments.isEmpty { events.append(.blockDelta(index: block, delta: .inputJSON(arguments))) }
        return events
    }

    private mutating func textDelta(_ json: JSONValue) -> [LLMStreamEvent] {
        guard let delta = json["delta"]?.stringValue, !delta.isEmpty else { return [] }
        let key = TextKey(outputIndex: json["output_index"]?.intValue ?? 0, contentIndex: json["content_index"]?.intValue ?? 0)

        var events: [LLMStreamEvent] = []
        var text = delta
        let block: Int
        if let existing = textBlocks[key] {
            block = existing
        } else {
            block = allocateBlock()
            textBlocks[key] = block
            events.append(.blockStart(index: block, block: .text("")))
            // A second message in one response reads as a new paragraph, not a run-on.
            if sawText { text = "\n\n" + text }
            sawText = true
        }
        events.append(.blockDelta(index: block, delta: .text(text)))
        return events
    }

    private mutating func argumentsDelta(_ json: JSONValue) -> [LLMStreamEvent] {
        guard let outputIndex = json["output_index"]?.intValue, var call = calls[outputIndex],
            let delta = json["delta"]?.stringValue, !delta.isEmpty
        else { return [] }
        call.receivedArguments = true
        calls[outputIndex] = call
        return [.blockDelta(index: call.block, delta: .inputJSON(delta))]
    }

    /// The complete arguments arrive here too. They are only needed if no fragments came.
    private mutating func argumentsDone(_ json: JSONValue) -> [LLMStreamEvent] {
        guard let outputIndex = json["output_index"]?.intValue, var call = calls[outputIndex], !call.receivedArguments,
            let arguments = json["arguments"]?.stringValue, !arguments.isEmpty
        else { return [] }
        call.receivedArguments = true
        calls[outputIndex] = call
        return [.blockDelta(index: call.block, delta: .inputJSON(arguments))]
    }

    private mutating func itemDone(_ json: JSONValue) -> [LLMStreamEvent] {
        let outputIndex = json["output_index"]?.intValue ?? -1
        var events: [LLMStreamEvent] = []

        if var call = calls[outputIndex] {
            if !call.receivedArguments, let arguments = json["item"]?["arguments"]?.stringValue, !arguments.isEmpty {
                events.append(.blockDelta(index: call.block, delta: .inputJSON(arguments)))
                call.receivedArguments = true
                calls[outputIndex] = call
            }
            events += close(call.block)
        }
        for (key, block) in textBlocks where key.outputIndex == outputIndex {
            events += close(block)
        }
        return events
    }

    private mutating func close(_ block: Int) -> [LLMStreamEvent] {
        guard let position = openBlocks.firstIndex(of: block) else { return [] }
        openBlocks.remove(at: position)
        return [.blockStop(index: block)]
    }

    private mutating func finish(response: JSONValue?, incomplete: Bool) -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for block in openBlocks { events.append(.blockStop(index: block)) }
        openBlocks.removeAll()

        let stopReason: StopReason
        if incomplete {
            switch response?["incomplete_details"]?["reason"]?.stringValue {
            case "max_output_tokens": stopReason = .maxTokens
            case "content_filter": stopReason = .refusal(category: "content_filter")
            case let other?: stopReason = .other(other)
            case nil: stopReason = .other("incomplete")
            }
        } else if sawCall {
            stopReason = .toolUse
        } else if sawRefusal {
            stopReason = .refusal(category: nil)
        } else {
            stopReason = .endTurn
        }

        events.append(.messageDelta(stopReason: stopReason, usage: response?["usage"].map(Self.usage(from:))))
        events.append(.messageStop)
        isComplete = true
        return events
    }

    // MARK: Values

    /// OpenAI counts cached tokens inside `input_tokens`; Voxa's `Usage` reports them separately, as Claude does.
    static func usage(from json: JSONValue) -> Usage {
        let input = json["input_tokens"]?.intValue ?? 0
        let cached = json["input_tokens_details"]?["cached_tokens"]?.intValue ?? 0
        return Usage(
            inputTokens: max(input - cached, 0),
            outputTokens: json["output_tokens"]?.intValue ?? 0,
            cacheReadInputTokens: cached,
            cacheCreationInputTokens: 0
        )
    }

    /// An error inside a stream (`error` events, and the `error` of a `response.failed`).
    static func failure(_ json: JSONValue?) -> LLMError {
        let code = json?["code"]?.stringValue ?? ""
        let message = json?["message"]?.stringValue ?? "The response failed."
        return OpenAIClient.mapped(code: code, type: json?["type"]?.stringValue, message: message)
    }
}
