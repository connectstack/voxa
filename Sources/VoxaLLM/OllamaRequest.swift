import Foundation
import VoxaCore

/// How much a model should think before answering, as Ollama's `think` field takes it.
enum OllamaThink: Sendable, Equatable {
    case off
    case level(String)

    var json: JSONValue {
        switch self {
        case .off: false
        case .level(let level): .string(level)
        }
    }
}

/// Builds the request for Ollama's native chat API (`POST /api/chat`).
///
/// The native API is used instead of the OpenAI-compatible one because it takes what a voice assistant needs to behave
/// well: the context window per request (Ollama's default silently truncates Voxa's prompt and tool list), how long the
/// model stays loaded between commands, and whether to think.
struct OllamaRequestBuilder: Sendable {
    /// The server's address, for example `http://localhost:11434`.
    let baseURL: URL

    /// Keep the model in memory between commands, so only the first one pays the load time.
    static let keepAlive = "30m"
    /// A cap on generated tokens: replies are short, and an unbounded loop on a small model is worth stopping.
    static let maxGeneratedTokens = 4_096

    func urlRequest(for request: LLMRequest, think: OllamaThink?) throws -> URLRequest {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("application/x-ndjson", forHTTPHeaderField: "accept")
        urlRequest.httpBody = try WireJSON.encode(body(for: request, think: think))
        return urlRequest
    }

    func body(for request: LLMRequest, think: OllamaThink?) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": true,
            "messages": .array(Self.messages(system: request.system, conversation: request.messages)),
            "keep_alive": .string(Self.keepAlive),
            "options": [
                "num_ctx": .int(request.contextLength ?? AppSettings.defaultOllamaContextLength),
                "num_predict": .int(min(request.maxTokens, Self.maxGeneratedTokens)),
            ],
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(
                request.tools.sorted { $0.name < $1.name }.map { tool in
                    [
                        "type": "function",
                        "function": [
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "parameters": tool.inputSchema,
                        ],
                    ]
                }
            )
        }
        if let think { body["think"] = think.json }
        return .object(body)
    }

    // MARK: Conversation

    /// The conversation as chat messages. Ollama identifies a tool result by the *name* of the tool, not by an id, so the names
    /// are remembered from the assistant messages that made the calls.
    static func messages(system: [SystemBlock], conversation: [LLMMessage]) -> [JSONValue] {
        var out: [JSONValue] = []
        let systemText = system.map(\.text).joined(separator: "\n\n")
        if !systemText.isEmpty { out.append(["role": "system", "content": .string(systemText)]) }

        var toolNames: [String: String] = [:]
        for message in conversation {
            switch message.role {
            case .user: out += userMessages(message.content, toolNames: toolNames)
            case .assistant: out += assistantMessage(message.content, toolNames: &toolNames)
            }
        }
        return out
    }

    private static func userMessages(_ content: [ContentBlock], toolNames: [String: String]) -> [JSONValue] {
        var out: [JSONValue] = []
        var text: [String] = []

        func flush() {
            guard !text.isEmpty else { return }
            out.append(["role": "user", "content": .string(text.joined(separator: "\n\n"))])
            text.removeAll()
        }
        for block in content {
            switch block {
            case .text(let value):
                text.append(value)
            case .toolResult(let id, let parts, let isError):
                flush()
                out += toolResult(id: id, parts: parts, isError: isError, name: toolNames[id] ?? "")
            case .toolUse, .raw:
                continue
            }
        }
        flush()
        return out
    }

    private static func toolResult(id: String, parts: [ToolResultBlock], isError: Bool, name: String) -> [JSONValue] {
        let words = parts.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined(separator: "\n")
        var out: [JSONValue] = [
            ["role": "tool", "tool_name": .string(name), "content": .string((isError ? "Error: " : "") + words)]
        ]
        // A tool message carries text only; an image the tool returned goes in a user message right after it.
        let images = parts.compactMap { part -> JSONValue? in
            if case .image(_, let base64) = part { .string(base64) } else { nil }
        }
        if !images.isEmpty {
            out.append(["role": "user", "content": .string("The image returned by \(name.isEmpty ? "the tool" : name):"), "images": .array(images)])
        }
        return out
    }

    private static func assistantMessage(_ content: [ContentBlock], toolNames: inout [String: String]) -> [JSONValue] {
        var text: [String] = []
        var calls: [JSONValue] = []
        for block in content {
            switch block {
            case .text(let value):
                if !value.isEmpty { text.append(value) }
            case .toolUse(let id, let name, let input):
                toolNames[id] = name
                calls.append(["function": ["name": .string(name), "arguments": input]])
            case .toolResult, .raw:
                continue
            }
        }
        guard !text.isEmpty || !calls.isEmpty else { return [] }
        var message: [String: JSONValue] = ["role": "assistant", "content": .string(text.joined(separator: "\n\n"))]
        if !calls.isEmpty { message["tool_calls"] = .array(calls) }
        return [.object(message)]
    }
}
