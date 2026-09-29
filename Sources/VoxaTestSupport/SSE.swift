import Foundation
import VoxaCore

/// Builders for the Anthropic streaming wire format, so tests read as scenarios ("a text answer", "a tool call whose JSON
/// arrives in three fragments") instead of blobs of event text.
public enum SSE {
    public static func event(_ type: String, _ payload: JSONValue) -> String {
        var object = payload.objectValue ?? [:]
        object["type"] = .string(type)
        return "event: \(type)\ndata: \(JSONValue.object(object).serialized())\n\n"
    }

    public static func messageStart(id: String = "msg_01", model: String = "claude-sonnet-5-5", inputTokens: Int = 25) -> String {
        event("message_start", [
            "message": [
                "id": .string(id), "type": "message", "role": "assistant", "model": .string(model),
                "content": [], "stop_reason": nil,
                "usage": ["input_tokens": .int(inputTokens), "output_tokens": 1],
            ],
        ])
    }

    public static func ping() -> String {
        event("ping", [:])
    }

    public static func textBlock(index: Int = 0, _ pieces: [String]) -> String {
        var text = event("content_block_start", ["index": .int(index), "content_block": ["type": "text", "text": ""]])
        for piece in pieces {
            text += event("content_block_delta", [
                "index": .int(index), "delta": ["type": "text_delta", "text": .string(piece)],
            ])
        }
        return text + event("content_block_stop", ["index": .int(index)])
    }

    public static func toolUseBlock(index: Int = 0, id: String, name: String, jsonPieces: [String]) -> String {
        var text = event("content_block_start", [
            "index": .int(index),
            "content_block": ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]],
        ])
        for piece in jsonPieces {
            text += event("content_block_delta", [
                "index": .int(index), "delta": ["type": "input_json_delta", "partial_json": .string(piece)],
            ])
        }
        return text + event("content_block_stop", ["index": .int(index)])
    }

    public static func thinkingBlock(index: Int = 0, text: String = "", signature: String) -> String {
        var out = event("content_block_start", [
            "index": .int(index), "content_block": ["type": "thinking", "thinking": "", "signature": ""],
        ])
        if !text.isEmpty {
            out += event("content_block_delta", ["index": .int(index), "delta": ["type": "thinking_delta", "thinking": .string(text)]])
        }
        out += event("content_block_delta", [
            "index": .int(index), "delta": ["type": "signature_delta", "signature": .string(signature)],
        ])
        return out + event("content_block_stop", ["index": .int(index)])
    }

    /// A block sent whole, e.g. `redacted_thinking` or `fallback`.
    public static func wholeBlock(index: Int, _ block: JSONValue) -> String {
        event("content_block_start", ["index": .int(index), "content_block": block])
            + event("content_block_stop", ["index": .int(index)])
    }

    public static func messageEnd(stopReason: String = "end_turn", category: String? = nil, outputTokens: Int = 12) -> String {
        var delta: [String: JSONValue] = ["stop_reason": .string(stopReason), "stop_sequence": nil]
        if let category { delta["stop_details"] = ["type": "refusal", "category": .string(category)] }
        return event("message_delta", ["delta": .object(delta), "usage": ["output_tokens": .int(outputTokens)]])
            + event("message_stop", [:])
    }

    public static func errorEvent(type: String, message: String) -> String {
        event("error", ["error": ["type": .string(type), "message": .string(message)]])
    }

    /// A complete text answer.
    public static func textMessage(_ text: String, id: String = "msg_01") -> String {
        messageStart(id: id) + textBlock(["\(text)"]) + messageEnd()
    }

    /// A complete turn that asks for one tool.
    public static func toolCallMessage(
        id: String = "msg_01", toolID: String = "toolu_01", name: String, input: JSONValue, preamble: String? = nil
    ) -> String {
        var out = messageStart(id: id)
        var index = 0
        if let preamble {
            out += textBlock(index: index, [preamble])
            index += 1
        }
        out += toolUseBlock(index: index, id: toolID, name: name, jsonPieces: [input.serialized()])
        return out + messageEnd(stopReason: "tool_use")
    }

    /// Splits `text` into `size`-byte pieces. Pieces may cut a multi-byte character in half, exactly as a real network can.
    public static func chunked(_ text: String, size: Int) -> [Data] {
        let bytes = Array(text.utf8)
        guard size < bytes.count else { return [Data(bytes)] }
        return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0..<min($0 + size, bytes.count)]) }
    }
}
