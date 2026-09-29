import Foundation

/// Which service turns a command into actions. Each has its own wire protocol, its own model names and, for two of the three,
/// its own API key; everything after the model client (the agent loop, the policy, the tools) is the same for all of them.
public enum ModelProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Claude, through Anthropic's Messages API.
    case anthropic
    /// OpenAI's models (GPT), through the Responses API.
    case openAI
    /// A model served by Ollama, by default on this Mac.
    case ollama

    public var id: String { rawValue }

    /// The name people know it by.
    public var displayName: String {
        switch self {
        case .anthropic: L10n.Provider.anthropic
        case .openAI: L10n.Provider.openAI
        case .ollama: L10n.Provider.ollama
        }
    }

    /// Whether requests carry an API key that lives in the Keychain.
    public var usesAPIKey: Bool {
        self != .ollama
    }

    /// The Keychain account that holds this provider's key, if it has one.
    public var keychainAccount: String? {
        switch self {
        case .anthropic: "anthropic-api-key"
        case .openAI: "openai-api-key"
        case .ollama: nil
        }
    }
}
