import Foundation

/// What a model accepts on the wire. Getting this wrong is a 400, so the request builder sends only what a model is known to
/// support and otherwise sends the smallest request that works everywhere. Facts come from Anthropic's model documentation
/// (for example, `claude-sonnet-5-5` rejects `budget_tokens`, a disabled `thinking` block, non-default sampling parameters
/// and forced `tool_choice`, and accepts `output_config.effort`).
public struct ModelCapabilities: Sendable, Equatable {
    /// Accepts `output_config: {effort: ...}`.
    public var supportsEffort: Bool
    /// Accepts the server-side refusal fallback (`fallbacks: "default"` with its beta header).
    public var supportsRefusalFallback: Bool

    public static let minimal = ModelCapabilities(supportsEffort: false, supportsRefusalFallback: false)

    public init(supportsEffort: Bool, supportsRefusalFallback: Bool) {
        self.supportsEffort = supportsEffort
        self.supportsRefusalFallback = supportsRefusalFallback
    }

    /// Model families that accept `effort`. Prefix matches also cover dated snapshots of the same model.
    private static let effortPrefixes = [
        "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
        "claude-sonnet-4-6", "claude-sonnet-5", "claude-fable-5", "claude-mythos-5",
    ]

    /// Models on which the `"default"` fallback mode is documented.
    private static let fallbackPrefixes = ["claude-fable-5-1", "claude-opus-5", "claude-sonnet-5-5"]

    public static func forModel(_ id: String) -> ModelCapabilities {
        let id = id.lowercased()
        return ModelCapabilities(
            supportsEffort: effortPrefixes.contains { id.hasPrefix($0) },
            supportsRefusalFallback: fallbackPrefixes.contains { id.hasPrefix($0) }
        )
    }
}
