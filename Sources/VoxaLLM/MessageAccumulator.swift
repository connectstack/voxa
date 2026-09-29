import Foundation
import VoxaCore

/// Rebuilds a complete assistant message from stream events. Pure and synchronous, so the tricky parts (tool input
/// arriving as JSON fragments, thinking signatures, unknown blocks, restarts) are unit-testable without a network.
public struct MessageAccumulator: Sendable {
    private enum Slot {
        case text(String)
        case toolUse(id: String, name: String, json: String)
        case thinking(text: String, signature: String)
        case other(JSONValue)
    }

    private var id = ""
    private var model = ""
    private var usage = Usage()
    private var stopReason: StopReason?
    private var slots: [Int: Slot] = [:]
    private var sawStart = false
    private var sawStop = false

    public init() {}

    /// Whether `messageStart` has been seen (used to decide whether a retry needs to tell the consumer to reset).
    public var hasStarted: Bool { sawStart }

    public mutating func apply(_ event: LLMStreamEvent) throws {
        switch event {
        case .messageStart(let id, let model, let usage):
            self = MessageAccumulator()
            self.id = id
            self.model = model
            if let usage { self.usage.merge(usage) }
            sawStart = true

        case .blockStart(let index, let block):
            switch block {
            case .text(let text): slots[index] = .text(text)
            case .toolUse(let id, let name): slots[index] = .toolUse(id: id, name: name, json: "")
            case .thinking: slots[index] = .thinking(text: "", signature: "")
            case .other(let json): slots[index] = .other(json)
            }

        case .blockDelta(let index, let delta):
            guard let slot = slots[index] else { return }
            switch (slot, delta) {
            case (.text(let text), .text(let more)):
                slots[index] = .text(text + more)
            case (.toolUse(let id, let name, let json), .inputJSON(let more)):
                slots[index] = .toolUse(id: id, name: name, json: json + more)
            case (.thinking(let text, let signature), .thinking(let more)):
                slots[index] = .thinking(text: text + more, signature: signature)
            case (.thinking(let text, let signature), .signature(let more)):
                slots[index] = .thinking(text: text, signature: signature + more)
            default:
                break   // a delta that doesn't fit its block is ignored
            }

        case .blockStop:
            break

        case .messageDelta(let reason, let usage):
            if let reason { stopReason = reason }
            if let usage { self.usage.merge(usage) }

        case .messageStop:
            sawStop = true

        case .ping:
            break

        case .restarted:
            self = MessageAccumulator()
        }
    }

    /// The assembled message. Throws if the stream ended before `message_stop`.
    public func finish() throws -> LLMResponse {
        guard sawStart, sawStop else { throw LLMError.incompleteStream }

        var content: [ContentBlock] = []
        var malformed: [String: String] = [:]

        for index in slots.keys.sorted() {
            switch slots[index] {
            case .text(let text)?:
                // The API rejects empty text blocks in a request, so an empty one must not be echoed back.
                if !text.isEmpty { content.append(.text(text)) }

            case .toolUse(let id, let name, let json)?:
                let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    content.append(.toolUse(id: id, name: name, input: .object([:])))
                } else if let parsed = try? JSONValue.parse(trimmed), parsed.objectValue != nil {
                    content.append(.toolUse(id: id, name: name, input: parsed))
                } else {
                    malformed[id] = json
                    content.append(.toolUse(id: id, name: name, input: .object([:])))
                }

            case .thinking(let text, let signature)?:
                content.append(.raw(["type": "thinking", "thinking": .string(text), "signature": .string(signature)]))

            case .other(let json)?:
                content.append(.raw(json))

            case nil:
                break
            }
        }

        return LLMResponse(
            id: id, model: model, content: content, stopReason: stopReason, usage: usage, malformedToolInputs: malformed
        )
    }
}
