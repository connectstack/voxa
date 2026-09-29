import Foundation
import VoxaCore
import VoxaLLM

/// The "Test connection" button: one tiny real request to the provider that is chosen in Settings, so a wrong key, model or
/// address shows up now rather than on the first spoken command.
///
/// For Ollama it first checks the things that most often go wrong on their own: the server isn't running, the model isn't
/// installed, or the model can't use tools.
struct ProviderConnectionTest: Sendable {
    let llm: any LLMClient
    let ollama: any OllamaDiscovering
    let settings: @Sendable () async -> AppSettings

    /// Returns nil when the provider answers, or what to tell the user.
    func run(_ provider: ModelProvider) async -> UserFacingError? {
        var snapshot = await settings()
        snapshot.provider = provider

        if provider == .ollama, let problem = await checkOllama(snapshot) { return problem }

        let request = LLMRequest(
            model: snapshot.activeModel,
            maxTokens: 64,
            system: [SystemBlock("Reply with the single word OK.")],
            messages: [.user("Ping")],
            // A local model loads on the first request; a quick setting keeps a thinking model from reasoning about "Ping".
            effort: provider == .ollama ? .low : nil,
            provider: provider,
            endpoint: snapshot.activeBaseURL,
            contextLength: provider == .ollama ? snapshot.ollamaContextLength : nil
        )
        do {
            _ = try await llm.complete(request)
            return nil
        } catch {
            return UserFacingError.describing(error)
        }
    }

    private func checkOllama(_ settings: AppSettings) async -> UserFacingError? {
        func describe(_ error: LLMError) -> UserFacingError {
            UserFacingError.describing(ProviderFailure(provider: .ollama, error: error))
        }

        let model = settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return describe(.missingModel) }
        guard let address = OllamaClient.address(from: settings.ollamaBaseURL) else {
            return UserFacingError(title: L10n.SettingsProvider.ollamaBadAddress, detail: settings.ollamaBaseURL)
        }
        do {
            let details = try await ollama.details(of: model, at: address)
            return details.supportsTools ? nil : describe(.modelCannotUseTools(model))
        } catch let error as LLMError {
            return describe(error)
        } catch {
            return UserFacingError.describing(error)
        }
    }
}
