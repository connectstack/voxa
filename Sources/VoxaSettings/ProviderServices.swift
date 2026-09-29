import Foundation
import VoxaCore
import VoxaLLM

/// What the Model tab needs from the rest of the app: where each provider's key is kept, how to test a provider, how to ask an
/// Ollama server what it has, and how to open the Ollama app. Passed in so the tab can be tested and previewed without a
/// Keychain, a network or an installed Ollama.
public struct ProviderServices: Sendable {
    public var keys: [ModelProvider: any APIKeyStoring]
    /// A tiny real request to the chosen provider. Returns nil when it works.
    public var testConnection: @Sendable (ModelProvider) async -> UserFacingError?
    public var ollama: any OllamaDiscovering
    public var openOllama: @MainActor @Sendable () -> Void

    public init(
        keys: [ModelProvider: any APIKeyStoring],
        testConnection: @escaping @Sendable (ModelProvider) async -> UserFacingError?,
        ollama: any OllamaDiscovering,
        openOllama: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.keys = keys
        self.testConnection = testConnection
        self.ollama = ollama
        self.openOllama = openOllama
    }

    /// Nothing behind it: keys are held in memory, every test passes, and no Ollama server is ever found.
    public static var inert: ProviderServices {
        ProviderServices(
            keys: Dictionary(uniqueKeysWithValues: ModelProvider.allCases.map { ($0, InMemoryAPIKeyStore() as any APIKeyStoring) }),
            testConnection: { _ in nil },
            ollama: OfflineOllama()
        )
    }
}

/// An Ollama server that is never there.
private struct OfflineOllama: OllamaDiscovering {
    func version(at baseURL: URL) async throws -> String { throw LLMError.unreachable(baseURL.host ?? "") }
    func models(at baseURL: URL) async throws -> [OllamaModel] { throw LLMError.unreachable(baseURL.host ?? "") }
    func details(of model: String, at baseURL: URL) async throws -> OllamaModelDetails {
        throw LLMError.unreachable(baseURL.host ?? "")
    }
}
