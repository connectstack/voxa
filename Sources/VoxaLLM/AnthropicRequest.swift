import Foundation
import VoxaCore

/// Builds the Messages API request. Kept separate from the client so the exact bytes that go over the wire can be pinned by
/// tests: the system prompt and tool list must stay byte-stable for prompt caching, and each model gets only the parameters
/// it accepts.
struct AnthropicRequestBuilder: Sendable {
    static let apiVersion = "2023-06-01"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    let baseURL: URL

    /// Whether the fallback parameter may be sent at all: the model must document it and the request must go to Anthropic
    /// itself (a proxy or gateway may reject an unknown field).
    func allowsRefusalFallback(for request: LLMRequest) -> Bool {
        request.useRefusalFallback
            && ModelCapabilities.forModel(request.model).supportsRefusalFallback
            && baseURL.host?.lowercased() == "api.anthropic.com"
    }

    func urlRequest(for request: LLMRequest, apiKey: String, useFallback: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if useFallback {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try Self.encode(body(for: request, useFallback: useFallback))
        return urlRequest
    }

    func body(for request: LLMRequest, useFallback: Bool) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .int(request.maxTokens),
            "stream": true,
            "messages": .array(Self.messages(request.messages, cacheLast: request.cacheConversation)),
        ]

        if !request.system.isEmpty {
            body["system"] = .array(request.system.map { block in
                var wire: [String: JSONValue] = ["type": "text", "text": .string(block.text)]
                if block.cacheBreakpoint { wire["cache_control"] = ["type": "ephemeral"] }
                return .object(wire)
            })
        }

        if !request.tools.isEmpty {
            // Sorted by name: a different order would change the prefix and miss the cache.
            body["tools"] = .array(request.tools.sorted { $0.name < $1.name }.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "input_schema": tool.inputSchema]
            })
        }

        if let effort = request.effort, ModelCapabilities.forModel(request.model).supportsEffort {
            body["output_config"] = ["effort": .string(effort.rawValue)]
        }
        if useFallback {
            body["fallbacks"] = "default"
        }
        return .object(body)
    }

    // MARK: Messages

    static func messages(_ messages: [LLMMessage], cacheLast: Bool) -> [JSONValue] {
        messages.enumerated().map { index, message in
            var blocks = message.content.map(wire(_:))
            if cacheLast, index == messages.count - 1, let last = blocks.indices.last,
               case .object(var object) = blocks[last],
               ["text", "tool_result"].contains(object["type"]?.stringValue) {
                object["cache_control"] = ["type": "ephemeral"]
                blocks[last] = .object(object)
            }
            return ["role": .string(message.role.rawValue), "content": .array(blocks)]
        }
    }

    static func wire(_ block: ContentBlock) -> JSONValue {
        switch block {
        case .text(let text):
            ["type": "text", "text": .string(text)]

        case .toolUse(let id, let name, let input):
            ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]

        case .toolResult(let toolUseID, let content, let isError):
            {
                var wire: [String: JSONValue] = [
                    "type": "tool_result",
                    "tool_use_id": .string(toolUseID),
                    "content": .array(content.map { part in
                        switch part {
                        case .text(let text):
                            ["type": "text", "text": .string(text)]
                        case .image(let mediaType, let base64):
                            ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)]]
                        }
                    }),
                ]
                if isError { wire["is_error"] = true }
                return .object(wire)
            }()

        case .raw(let json):
            json
        }
    }

    static func encode(_ value: JSONValue) throws -> Data {
        try WireJSON.encode(value)
    }
}

/// How request bodies are written: keys sorted and slashes left alone, so identical requests are identical bytes (which is
/// what makes a cached prompt prefix hit) and tests can compare them.
enum WireJSON {
    static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
