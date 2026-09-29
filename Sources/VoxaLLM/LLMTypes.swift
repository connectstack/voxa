import Foundation
import VoxaCore

// MARK: - Messages

public enum LLMRole: String, Codable, Sendable {
    case user
    case assistant
}

/// One part of a tool's result as the API represents it.
public enum ToolResultBlock: Sendable, Equatable {
    case text(String)
    case image(mediaType: String, base64: String)
}

/// A content block in a message.
public enum ContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: [ToolResultBlock], isError: Bool)
    /// A block the model produced that must be echoed back **verbatim** but that the app doesn't interpret: `thinking`
    /// (with its signature), `redacted_thinking`, `fallback` markers and any type added in the future. Keeping the JSON
    /// exactly as received is what lets the API validate the model's earlier reasoning on the next request.
    case raw(JSONValue)

    /// The block's `type` for `.raw` blocks.
    public var rawType: String? {
        if case .raw(let json) = self { json["type"]?.stringValue } else { nil }
    }
}

public struct LLMMessage: Sendable, Equatable {
    public var role: LLMRole
    public var content: [ContentBlock]

    public init(role: LLMRole, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> LLMMessage {
        LLMMessage(role: .user, content: [.text(text)])
    }

    /// Whether any tool result in the message carries a picture.
    public var containsImages: Bool {
        content.contains { block in
            guard case .toolResult(_, let parts, _) = block else { return false }
            return parts.contains { if case .image = $0 { true } else { false } }
        }
    }

    /// The same message with each picture in a tool result replaced by `note`, for a model that can't take pictures.
    public func replacingImages(with note: String) -> LLMMessage {
        LLMMessage(
            role: role,
            content: content.map { block in
                guard case .toolResult(let id, let parts, let isError) = block else { return block }
                return .toolResult(
                    toolUseID: id,
                    content: parts.map { if case .image = $0 { .text(note) } else { $0 } },
                    isError: isError
                )
            }
        )
    }
}

// MARK: - Request

/// A block of the system prompt. `cacheBreakpoint` marks the end of a prefix the API may cache.
public struct SystemBlock: Sendable, Equatable {
    public var text: String
    public var cacheBreakpoint: Bool

    public init(_ text: String, cacheBreakpoint: Bool = true) {
        self.text = text
        self.cacheBreakpoint = cacheBreakpoint
    }
}

public struct LLMRequest: Sendable, Equatable {
    public var model: String
    public var maxTokens: Int
    public var system: [SystemBlock]
    public var messages: [LLMMessage]
    public var tools: [ToolDefinition]
    /// Sent only to models that support it; ignored for the rest.
    public var effort: ReasoningEffort?
    /// Opt in to Anthropic's server-side refusal fallback. Only honored for models and hosts that support it.
    public var useRefusalFallback: Bool
    /// Mark the end of the conversation as a cache breakpoint so each agent step reuses the previous steps' prefix.
    public var cacheConversation: Bool
    /// Which service answers. The model name is only meaningful to that service.
    public var provider: ModelProvider
    /// The server address to use instead of the provider's built-in one (a self-hosted or gateway address, or Ollama's).
    public var endpoint: URL?
    /// Ollama only: the context window to ask for, in tokens.
    public var contextLength: Int?

    public init(
        model: String,
        maxTokens: Int = 16_000,
        system: [SystemBlock],
        messages: [LLMMessage],
        tools: [ToolDefinition] = [],
        effort: ReasoningEffort? = nil,
        useRefusalFallback: Bool = false,
        cacheConversation: Bool = true,
        provider: ModelProvider = .anthropic,
        endpoint: URL? = nil,
        contextLength: Int? = nil
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.contextLength = contextLength
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.tools = tools
        self.effort = effort
        self.useRefusalFallback = useRefusalFallback
        self.cacheConversation = cacheConversation
    }
}

// MARK: - Response

public enum StopReason: Sendable, Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    /// The API declined the request. `category` is informational and may be `nil`.
    case refusal(category: String?)
    case pauseTurn
    case other(String)

    init(wire: String, category: String? = nil) {
        switch wire {
        case "end_turn": self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal(category: category)
        case "pause_turn": self = .pauseTurn
        default: self = .other(wire)
        }
    }
}

public struct Usage: Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadInputTokens: Int
    public var cacheCreationInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadInputTokens: Int = 0, cacheCreationInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    /// Adds the counts of a separate request, for totalling a whole command.
    public mutating func add(_ other: Usage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
    }

    /// Folds in a cumulative report from the same request, keeping the larger figure.
    mutating func merge(_ other: Usage) {
        inputTokens = max(inputTokens, other.inputTokens)
        outputTokens = max(outputTokens, other.outputTokens)
        cacheReadInputTokens = max(cacheReadInputTokens, other.cacheReadInputTokens)
        cacheCreationInputTokens = max(cacheCreationInputTokens, other.cacheCreationInputTokens)
    }
}

/// The complete assistant turn, rebuilt from the stream.
public struct LLMResponse: Sendable, Equatable {
    public var id: String
    public var model: String
    public var content: [ContentBlock]
    public var stopReason: StopReason?
    public var usage: Usage
    /// Tool calls whose streamed input was not valid JSON, keyed by tool-use id, with the raw text received. They must
    /// never run; the agent loop answers them with an error result so the model can retry.
    public var malformedToolInputs: [String: String]

    public init(
        id: String = "",
        model: String = "",
        content: [ContentBlock] = [],
        stopReason: StopReason? = nil,
        usage: Usage = Usage(),
        malformedToolInputs: [String: String] = [:]
    ) {
        self.id = id
        self.model = model
        self.content = content
        self.stopReason = stopReason
        self.usage = usage
        self.malformedToolInputs = malformedToolInputs
    }

    /// The text blocks joined, i.e. what the model said.
    public var text: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    /// The index just past the last `fallback` marker, or 0 if there is none. Everything before it came from a model that
    /// declined the request and must not be acted on.
    private var fallbackBoundary: Int {
        content.lastIndex { $0.rawType == "fallback" }.map { $0 + 1 } ?? 0
    }

    /// Tool calls that may be executed: those after the last fallback boundary. A tool call in the discarded partial output
    /// of a model that refused is never run.
    public var executableToolUses: [(id: String, name: String, input: JSONValue)] {
        content.dropFirst(fallbackBoundary).compactMap {
            if case .toolUse(let id, let name, let input) = $0 { (id, name, input) } else { nil }
        }
    }

    /// The assistant content to append to the conversation. After a mid-output fallback, the API requires dropping the
    /// declined partial's thinking and tool-use blocks (text may stay) and treats the marker itself as ignorable.
    public var contentForHistory: [ContentBlock] {
        guard let marker = content.lastIndex(where: { $0.rawType == "fallback" }) else { return content }
        let before = content[..<marker].filter { if case .text = $0 { true } else { false } }
        return Array(before) + Array(content[(marker + 1)...])
    }
}

// MARK: - Streaming events

public struct StopDetails: Sendable, Equatable {
    public var category: String?
    public var explanation: String?

    public init(category: String? = nil, explanation: String? = nil) {
        self.category = category
        self.explanation = explanation
    }
}

public enum StartedBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String)
    /// A `thinking` block; its text and signature arrive as deltas.
    case thinking
    /// Any other block, complete as sent (`redacted_thinking`, `fallback`, future types).
    case other(JSONValue)
}

public enum BlockDelta: Sendable, Equatable {
    case text(String)
    case inputJSON(String)
    case thinking(String)
    case signature(String)
    case unknown
}

public enum LLMStreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String, usage: Usage?)
    case blockStart(index: Int, block: StartedBlock)
    case blockDelta(index: Int, delta: BlockDelta)
    case blockStop(index: Int)
    case messageDelta(stopReason: StopReason?, usage: Usage?)
    case messageStop
    case ping
    /// A retryable failure happened after events were already delivered; discard everything so far. What follows is a fresh
    /// response.
    case restarted(attempt: Int)
}

public protocol LLMClient: Sendable {
    /// Streams one assistant turn. Cancelling the consuming task cancels the request.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error>
}

extension LLMClient {
    /// Runs a request to completion and returns the assembled turn, reporting each event to `onEvent` as it arrives.
    public func complete(
        _ request: LLMRequest,
        onEvent: (@Sendable (LLMStreamEvent) -> Void)? = nil
    ) async throws -> LLMResponse {
        var accumulator = MessageAccumulator()
        for try await event in stream(request) {
            try accumulator.apply(event)
            onEvent?(event)
        }
        // A cancelled consumer just sees the stream end. Report that as a cancellation, not as a truncated message.
        try Task.checkCancellation()
        return try accumulator.finish()
    }
}
