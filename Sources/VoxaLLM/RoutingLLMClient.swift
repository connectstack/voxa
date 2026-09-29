import Foundation
import VoxaCore

/// Sends each request to the client for the provider it names, so the rest of the app has one model client and the choice of
/// provider is a setting rather than a code path.
///
/// It also tells each failure which service it came from (`ProviderFailure`), so the words shown to the user are about the
/// right one: "OpenAI is busy", "Ollama isn't running".
public struct RoutingLLMClient: LLMClient {
    private let anthropic: any LLMClient
    private let openAI: any LLMClient
    private let ollama: any LLMClient

    public init(anthropic: any LLMClient, openAI: any LLMClient, ollama: any LLMClient) {
        self.anthropic = anthropic
        self.openAI = openAI
        self.ollama = ollama
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        let provider = request.provider
        let inner = client(for: provider).stream(request)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in inner { continuation.yield(event) }
                    continuation.finish()
                } catch let error as LLMError {
                    continuation.finish(throwing: ProviderFailure(provider: provider, error: error))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func client(for provider: ModelProvider) -> any LLMClient {
        switch provider {
        case .anthropic: anthropic
        case .openAI: openAI
        case .ollama: ollama
        }
    }
}
