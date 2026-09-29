import Foundation
import VoxaCore

/// What an OpenAI model accepts on the wire. Getting this wrong is a 400, so a parameter is sent only for models known to take
/// it; the client also drops it and retries if the server rejects it anyway (new models appear faster than this list).
struct OpenAICapabilities: Sendable, Equatable {
    /// Accepts `reasoning: {effort: ...}`.
    var supportsReasoningEffort: Bool
    /// Wants `phase` (commentary or final answer) kept on the assistant messages it is sent back. OpenAI's guidance for these
    /// models is to preserve it, because dropping it "can degrade performance": a preamble may be taken for a final answer.
    var usesMessagePhase: Bool

    /// Model families that reason. Prefix matches also cover snapshots and sized variants (`gpt-6-luna`, `gpt-5.6-sol`).
    private static let reasoningPrefixes = ["gpt-5", "gpt-6", "o1", "o3", "o4"]

    static func forModel(_ id: String) -> OpenAICapabilities {
        let id = id.lowercased()
        return OpenAICapabilities(
            supportsReasoningEffort: reasoningPrefixes.contains { id.hasPrefix($0) },
            usesMessagePhase: usesPhase(id)
        )
    }

    /// `gpt-5.3` and every later version (`gpt-5.4-…`, `gpt-6-…`). Earlier ones (`gpt-5`, `gpt-5.2`, `gpt-4o`, `o3`) don't.
    private static func usesPhase(_ id: String) -> Bool {
        guard id.hasPrefix("gpt-") else { return false }
        let version = id.dropFirst("gpt-".count).prefix { $0.isNumber || $0 == "." }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard let major = parts.first.flatMap({ Int($0) }) else { return false }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return major > 5 || (major == 5 && minor >= 3)
    }
}

/// Builds the Responses API request. Kept apart from the client so the exact bytes that go over the wire can be pinned by tests.
///
/// The conversation is sent **statelessly** (`store: false`, full history every time). That keeps the conversation on this Mac
/// (the server keeps nothing to look up later) and lets Voxa's own append-only history stay the single source of truth.
struct OpenAIRequestBuilder: Sendable {
    /// The API root, for example `https://api.openai.com/v1`.
    let baseURL: URL

    func urlRequest(
        for request: LLMRequest, apiKey: String, includeReasoning: Bool, includePhase: Bool = true
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("responses"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = try WireJSON.encode(
            body(for: request, includeReasoning: includeReasoning, includePhase: includePhase)
        )
        return urlRequest
    }

    func body(for request: LLMRequest, includeReasoning: Bool, includePhase: Bool = true) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": true,
            // Not stored on OpenAI's side: the full conversation is sent each time.
            "store": false,
            "max_output_tokens": .int(request.maxTokens),
            "input": .array(
                Self.input(
                    from: request.messages,
                    includePhase: includePhase && OpenAICapabilities.forModel(request.model).usesMessagePhase
                )
            ),
        ]

        let instructions = request.system.map(\.text).joined(separator: "\n\n")
        if !instructions.isEmpty { body["instructions"] = .string(instructions) }

        if !request.tools.isEmpty {
            // Sorted by name, as for Claude, so the cached prefix doesn't depend on registration order. `strict` is off on
            // purpose: the Responses API defaults it to on, which demands every property be required, and optional
            // arguments are how Voxa's tools are written. The agent validates arguments itself.
            body["tools"] = .array(
                request.tools.sorted { $0.name < $1.name }.map { tool in
                    [
                        "type": "function",
                        "name": .string(tool.name),
                        "description": .string(tool.description),
                        "parameters": tool.inputSchema,
                        "strict": false,
                    ]
                }
            )
        }

        if includeReasoning, let effort = request.effort, OpenAICapabilities.forModel(request.model).supportsReasoningEffort {
            body["reasoning"] = ["effort": .string(effort.rawValue)]
        }
        return .object(body)
    }

    // MARK: Conversation

    /// The conversation as Responses API items. Claude-specific blocks (`raw`) mean nothing here and are skipped.
    static func input(from messages: [LLMMessage], includePhase: Bool = false) -> [JSONValue] {
        var items: [JSONValue] = []
        for message in messages {
            switch message.role {
            case .user: items += userItems(message.content)
            case .assistant: items += assistantItems(message.content, includePhase: includePhase)
            }
        }
        return items
    }

    private static func userItems(_ content: [ContentBlock]) -> [JSONValue] {
        var items: [JSONValue] = []
        var pending: [String] = []

        func flush() {
            guard !pending.isEmpty else { return }
            items.append(["role": "user", "content": .string(pending.joined(separator: "\n\n"))])
            pending.removeAll()
        }
        for block in content {
            switch block {
            case .text(let text):
                pending.append(text)
            case .toolResult(let id, let parts, let isError):
                flush()
                items.append(functionCallOutput(id: id, parts: parts, isError: isError))
            case .toolUse, .raw:
                continue
            }
        }
        flush()
        return items
    }

    /// Words said before a tool call are the model's running commentary; words in a turn that makes no call are its final
    /// answer. That is how the API labels them when it sends them, so the label can be put back when they are sent again.
    private static func assistantItems(_ content: [ContentBlock], includePhase: Bool) -> [JSONValue] {
        let callsATool = content.contains { if case .toolUse = $0 { true } else { false } }
        return content.compactMap { block in
            switch block {
            case .text(let text):
                guard !text.isEmpty else { return nil }
                var item: [String: JSONValue] = ["role": "assistant", "content": .string(text)]
                if includePhase { item["phase"] = .string(callsATool ? "commentary" : "final_answer") }
                return .object(item)
            case .toolUse(let id, let name, let input):
                // No `id` on purpose: an item id ties the call to reasoning that isn't being replayed.
                return [
                    "type": "function_call", "call_id": .string(id), "name": .string(name),
                    "arguments": .string(input.serialized()),
                ]
            case .toolResult, .raw:
                return nil
            }
        }
    }

    static func functionCallOutput(id: String, parts: [ToolResultBlock], isError: Bool) -> JSONValue {
        // The API has no error flag on a tool result, so a failure says so in words.
        let prefix = isError ? "Error: " : ""
        let hasImage = parts.contains { if case .image = $0 { true } else { false } }

        let output: JSONValue
        if hasImage {
            var first = true
            output = .array(
                parts.map { part in
                    switch part {
                    case .text(let text):
                        defer { first = false }
                        return ["type": "input_text", "text": .string(first ? prefix + text : text)]
                    case .image(let mediaType, let base64):
                        first = false
                        return ["type": "input_image", "image_url": .string("data:\(mediaType);base64,\(base64)")]
                    }
                }
            )
        } else {
            let text = parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
            output = .string(prefix + text)
        }
        return ["type": "function_call_output", "call_id": .string(id), "output": output]
    }
}
