import Foundation
import VoxaCore
import VoxaLLM
import VoxaPolicy

/// What the model remembers between commands, so "also make it three hours" can follow "schedule lunch at noon".
///
/// The history is **append-only** while it lives: the API's prompt cache and the validity of the model's own reasoning
/// blocks both depend on earlier messages staying byte-identical. So instead of editing it, Voxa throws it away whole when
/// it can no longer be trusted to help: too old, built under different settings, or too long.
public struct ConversationMemory: Sendable, Equatable {
    public enum ResetReason: Sendable, Equatable {
        case expired
        case settingsChanged
        case tooLong
    }

    public static let maxMessages = 40
    public static let maxCharacters = 120_000

    public var messages: [LLMMessage] = []
    /// Outside content that is still in `messages`. It lives exactly as long as they do.
    public var taint = RunTaint()
    public var lastActivity: Date?
    /// A digest of everything that shapes a request (model, effort, prompt, tools). History built under one fingerprint
    /// isn't valid under another: cached prefixes and signed reasoning blocks would no longer match.
    public var fingerprint: String?

    public init() {}

    public var isEmpty: Bool { messages.isEmpty }

    /// Forgets the conversation when it should no longer be used, and reports why. Call before each command.
    @discardableResult
    public mutating func prepare(now: Date, window: TimeInterval, fingerprint current: String) -> ResetReason? {
        var reason: ResetReason?
        if let last = lastActivity, now.timeIntervalSince(last) > window {
            reason = .expired
        } else if let stored = fingerprint, stored != current {
            reason = .settingsChanged
        } else if messages.count > Self.maxMessages || approximateSize > Self.maxCharacters {
            reason = .tooLong
        }
        if reason != nil { reset() }
        fingerprint = current
        return reason
    }

    public mutating func reset() {
        messages = []
        taint = RunTaint()
        lastActivity = nil
    }

    /// Roughly how much text the history holds, which is what decides how long a request takes and costs.
    var approximateSize: Int {
        messages.reduce(0) { total, message in
            total + message.content.reduce(0) { $0 + size(of: $1) }
        }
    }

    private func size(of block: ContentBlock) -> Int {
        switch block {
        case .text(let text): text.count
        case .toolUse(_, let name, let input): name.count + input.serialized().count
        case .toolResult(_, let content, _):
            content.reduce(0) { total, part in
                switch part {
                case .text(let text): total + text.count
                case .image(_, let base64): total + base64.count / 100   // images cost tokens, not characters
                }
            }
        case .raw(let json): json.serialized().count
        }
    }
}
