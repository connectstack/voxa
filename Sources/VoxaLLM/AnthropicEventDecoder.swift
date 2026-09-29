import Foundation
import VoxaCore

/// Turns the API's Server-Sent Events into `LLMStreamEvent`s. Unknown event types are ignored so a new event added to the
/// API later can't break the app; a malformed known event is an error.
enum AnthropicEventDecoder {
    static func decode(_ event: SSEEvent) throws -> LLMStreamEvent? {
        guard !event.data.isEmpty else { return nil }
        let json: JSONValue
        do {
            json = try JSONValue.parse(event.data)
        } catch {
            throw LLMError.invalidResponse("unreadable event")
        }
        guard let type = json["type"]?.stringValue else { return nil }

        switch type {
        case "message_start":
            guard let message = json["message"] else { throw LLMError.invalidResponse("message_start without a message") }
            return .messageStart(
                id: message["id"]?.stringValue ?? "",
                model: message["model"]?.stringValue ?? "",
                usage: message["usage"].map(usage(from:))
            )

        case "content_block_start":
            guard let index = json["index"]?.intValue, let block = json["content_block"] else {
                throw LLMError.invalidResponse("content_block_start without an index or block")
            }
            return .blockStart(index: index, block: startedBlock(from: block))

        case "content_block_delta":
            guard let index = json["index"]?.intValue, let delta = json["delta"] else {
                throw LLMError.invalidResponse("content_block_delta without an index or delta")
            }
            return .blockDelta(index: index, delta: blockDelta(from: delta))

        case "content_block_stop":
            guard let index = json["index"]?.intValue else {
                throw LLMError.invalidResponse("content_block_stop without an index")
            }
            return .blockStop(index: index)

        case "message_delta":
            let delta = json["delta"]
            let category = delta?["stop_details"]?["category"]?.stringValue
            let reason = delta?["stop_reason"]?.stringValue.map { StopReason(wire: $0, category: category) }
            return .messageDelta(stopReason: reason, usage: json["usage"].map(usage(from:)))

        case "message_stop":
            return .messageStop

        case "ping":
            return .ping

        case "error":
            let error = json["error"]
            throw LLMError.stream(
                type: error?["type"]?.stringValue ?? "unknown_error",
                message: error?["message"]?.stringValue ?? "The stream reported an error."
            )

        default:
            return nil
        }
    }

    private static func startedBlock(from block: JSONValue) -> StartedBlock {
        switch block["type"]?.stringValue {
        case "text":
            .text(block["text"]?.stringValue ?? "")
        case "tool_use":
            .toolUse(id: block["id"]?.stringValue ?? "", name: block["name"]?.stringValue ?? "")
        case "thinking":
            .thinking
        default:
            .other(block)
        }
    }

    private static func blockDelta(from delta: JSONValue) -> BlockDelta {
        switch delta["type"]?.stringValue {
        case "text_delta": .text(delta["text"]?.stringValue ?? "")
        case "input_json_delta": .inputJSON(delta["partial_json"]?.stringValue ?? "")
        case "thinking_delta": .thinking(delta["thinking"]?.stringValue ?? "")
        case "signature_delta": .signature(delta["signature"]?.stringValue ?? "")
        default: .unknown
        }
    }

    private static func usage(from json: JSONValue) -> Usage {
        Usage(
            inputTokens: json["input_tokens"]?.intValue ?? 0,
            outputTokens: json["output_tokens"]?.intValue ?? 0,
            cacheReadInputTokens: json["cache_read_input_tokens"]?.intValue ?? 0,
            cacheCreationInputTokens: json["cache_creation_input_tokens"]?.intValue ?? 0
        )
    }
}
