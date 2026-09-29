import Foundation
import os
import VoxaCore
import VoxaLLM

/// Builders for OpenAI's Responses API streaming events, so tests read as scenarios ("a text answer", "two tool calls whose
/// arguments arrive in fragments"). Event names and fields follow OpenAI's published reference.
public enum OpenAISSE {
    public static func event(_ type: String, _ payload: JSONValue = [:]) -> String {
        var object = payload.objectValue ?? [:]
        object["type"] = .string(type)
        return "event: \(type)\ndata: \(JSONValue.object(object).serialized())\n\n"
    }

    public static func created(id: String = "resp_1", model: String = "gpt-6-luna") -> String {
        event("response.created", ["response": ["id": .string(id), "model": .string(model), "status": "in_progress", "output": []]])
            + event("response.in_progress", ["response": ["id": .string(id), "status": "in_progress"]])
    }

    /// An assistant message whose text arrives in `pieces`.
    public static func message(outputIndex: Int = 0, id: String = "msg_1", pieces: [String], phase: String? = nil) -> String {
        var item: [String: JSONValue] = ["type": "message", "id": .string(id), "status": "in_progress", "role": "assistant", "content": []]
        if let phase { item["phase"] = .string(phase) }
        var out = event("response.output_item.added", ["output_index": .int(outputIndex), "item": .object(item)])
        out += event("response.content_part.added", [
            "item_id": .string(id), "output_index": .int(outputIndex), "content_index": 0,
            "part": ["type": "output_text", "text": "", "annotations": []],
        ])
        for piece in pieces {
            out += event("response.output_text.delta", [
                "item_id": .string(id), "output_index": .int(outputIndex), "content_index": 0, "delta": .string(piece), "logprobs": [],
            ])
        }
        let full = pieces.joined()
        out += event("response.output_text.done", [
            "item_id": .string(id), "output_index": .int(outputIndex), "content_index": 0, "text": .string(full),
        ])
        out += event("response.content_part.done", [
            "item_id": .string(id), "output_index": .int(outputIndex), "content_index": 0,
            "part": ["type": "output_text", "text": .string(full), "annotations": []],
        ])
        item["status"] = "completed"
        item["content"] = [["type": "output_text", "text": .string(full), "annotations": []]]
        return out + event("response.output_item.done", ["output_index": .int(outputIndex), "item": .object(item)])
    }

    /// A function call whose JSON arguments arrive in `argumentPieces`.
    public static func functionCall(
        outputIndex: Int = 0,
        itemID: String = "fc_1",
        callID: String = "call_1",
        name: String,
        argumentPieces: [String],
        announceArguments: Bool = false
    ) -> String {
        let arguments = argumentPieces.joined()
        let added: JSONValue = [
            "type": "function_call", "id": .string(itemID), "call_id": .string(callID), "name": .string(name),
            "arguments": .string(announceArguments ? arguments : ""), "status": "in_progress",
        ]
        var out = event("response.output_item.added", ["output_index": .int(outputIndex), "item": added])
        if !announceArguments {
            for piece in argumentPieces {
                out += event("response.function_call_arguments.delta", [
                    "item_id": .string(itemID), "output_index": .int(outputIndex), "delta": .string(piece),
                ])
            }
            out += event("response.function_call_arguments.done", [
                "item_id": .string(itemID), "output_index": .int(outputIndex), "arguments": .string(arguments),
            ])
        }
        let done: JSONValue = [
            "type": "function_call", "id": .string(itemID), "call_id": .string(callID), "name": .string(name),
            "arguments": .string(arguments), "status": "completed",
        ]
        return out + event("response.output_item.done", ["output_index": .int(outputIndex), "item": done])
    }

    /// Hidden reasoning, which Voxa doesn't show.
    public static func reasoning(outputIndex: Int = 0, id: String = "rs_1") -> String {
        let item: JSONValue = ["type": "reasoning", "id": .string(id), "summary": [], "encrypted_content": "gAAAA"]
        return event("response.output_item.added", ["output_index": .int(outputIndex), "item": item])
            + event("response.output_item.done", ["output_index": .int(outputIndex), "item": item])
    }

    public static func completed(inputTokens: Int = 100, cachedTokens: Int = 0, outputTokens: Int = 20) -> String {
        event("response.completed", [
            "response": [
                "id": "resp_1", "status": "completed", "output": [],
                "usage": [
                    "input_tokens": .int(inputTokens),
                    "output_tokens": .int(outputTokens),
                    "total_tokens": .int(inputTokens + outputTokens),
                    "input_tokens_details": ["cached_tokens": .int(cachedTokens)],
                    "output_tokens_details": ["reasoning_tokens": 0],
                ],
            ],
        ])
    }

    public static func incomplete(reason: String) -> String {
        event("response.incomplete", [
            "response": ["id": "resp_1", "status": "incomplete", "incomplete_details": ["reason": .string(reason)], "output": []],
        ])
    }

    public static func failed(code: String, message: String) -> String {
        event("response.failed", [
            "response": ["id": "resp_1", "status": "failed", "error": ["code": .string(code), "message": .string(message)]],
        ])
    }

    public static func error(code: String, message: String) -> String {
        event("error", ["code": .string(code), "message": .string(message), "param": nil])
    }

    /// A complete text answer.
    public static func textResponse(_ text: String, id: String = "resp_1") -> String {
        created(id: id) + reasoning(outputIndex: 0) + message(outputIndex: 1, pieces: [text]) + completed()
    }

    /// A complete turn that asks for one tool.
    public static func toolCallResponse(name: String, input: JSONValue, callID: String = "call_1", preamble: String? = nil) -> String {
        var out = created()
        var index = 0
        out += reasoning(outputIndex: index)
        index += 1
        if let preamble {
            out += message(outputIndex: index, pieces: [preamble], phase: "commentary")
            index += 1
        }
        out += functionCall(outputIndex: index, itemID: "fc_\(callID)", callID: callID, name: name, argumentPieces: [input.serialized()])
        return out + completed()
    }
}

/// Builders for Ollama's native streaming chat format: one JSON object per line.
public enum OllamaNDJSON {
    public static func line(_ object: JSONValue) -> String {
        object.serialized() + "\n"
    }

    public static func textChunk(_ text: String, model: String = "qwen3:8b") -> String {
        line([
            "model": .string(model), "created_at": "2026-09-29T12:00:00Z",
            "message": ["role": "assistant", "content": .string(text)], "done": false,
        ])
    }

    public static func thinkingChunk(_ text: String, model: String = "qwen3:8b") -> String {
        line([
            "model": .string(model), "created_at": "2026-09-29T12:00:00Z",
            "message": ["role": "assistant", "content": "", "thinking": .string(text)], "done": false,
        ])
    }

    public static func toolCallChunk(name: String, arguments: JSONValue, model: String = "qwen3:8b") -> String {
        line([
            "model": .string(model), "created_at": "2026-09-29T12:00:00Z",
            "message": ["role": "assistant", "content": "", "tool_calls": [["function": ["name": .string(name), "arguments": arguments]]]],
            "done": false,
        ])
    }

    public static func done(
        reason: String = "stop",
        promptTokens: Int = 120,
        outputTokens: Int = 30,
        model: String = "qwen3:8b"
    ) -> String {
        line([
            "model": .string(model), "created_at": "2026-09-29T12:00:01Z", "message": ["role": "assistant", "content": ""],
            "done": true, "done_reason": .string(reason), "total_duration": 1_000_000_000, "load_duration": 1_000_000,
            "prompt_eval_count": .int(promptTokens), "eval_count": .int(outputTokens),
        ])
    }

    public static func errorLine(_ message: String) -> String {
        line(["error": .string(message)])
    }

    public static func textResponse(_ pieces: [String]) -> String {
        pieces.map { textChunk($0) }.joined() + done()
    }

    public static func toolCallResponse(name: String, arguments: JSONValue, preamble: String? = nil) -> String {
        (preamble.map { textChunk($0) } ?? "") + toolCallChunk(name: name, arguments: arguments) + done()
    }
}

extension MockHTTPTransport.Response {
    /// A non-200 response with the given JSON body.
    public static func json(status: Int, _ body: JSONValue, headers: [String: String] = [:]) -> MockHTTPTransport.Response {
        MockHTTPTransport.Response(status: status, headers: headers, chunks: [Data(body.serialized().utf8)])
    }

    /// An OpenAI-shaped error.
    public static func openAIError(
        status: Int, code: String? = nil, type: String = "invalid_request_error", message: String, headers: [String: String] = [:]
    ) -> MockHTTPTransport.Response {
        let error: JSONValue = [
            "message": .string(message), "type": .string(type), "param": .null,
            "code": code.map { JSONValue.string($0) } ?? JSONValue.null,
        ]
        return json(status: status, ["error": error], headers: headers)
    }

    /// An Ollama-shaped error (`{"error": "..."}`).
    public static func ollamaError(status: Int, message: String) -> MockHTTPTransport.Response {
        json(status: status, ["error": .string(message)])
    }
}

/// An Ollama server's answers, scripted, for tests that shouldn't need one.
public final class FakeOllamaDiscovery: OllamaDiscovering, @unchecked Sendable {
    private struct State {
        var models: [OllamaModel] = []
        var details: [String: OllamaModelDetails] = [:]
        var failure: (any Error)?
        var detailCalls = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(models: [OllamaModel] = [], details: [String: OllamaModelDetails] = [:], failure: (any Error)? = nil) {
        state.withLock {
            $0.models = models
            $0.details = details
            $0.failure = failure
        }
    }

    /// How many times a model's details were asked for.
    public var detailCalls: Int { state.withLock { $0.detailCalls } }

    public func version(at baseURL: URL) async throws -> String {
        if let failure = state.withLock({ $0.failure }) { throw failure }
        return "0.0.0-test"
    }

    public func models(at baseURL: URL) async throws -> [OllamaModel] {
        if let failure = state.withLock({ $0.failure }) { throw failure }
        return state.withLock { $0.models }
    }

    public func details(of model: String, at baseURL: URL) async throws -> OllamaModelDetails {
        state.withLock { $0.detailCalls += 1 }
        if let failure = state.withLock({ $0.failure }) { throw failure }
        guard let details = state.withLock({ $0.details[model] }) else { throw LLMError.modelNotInstalled(model) }
        return details
    }
}
