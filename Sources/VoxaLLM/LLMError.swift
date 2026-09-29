import Foundation
import VoxaCore

public enum LLMError: Error, Sendable, Equatable {
    case missingAPIKey
    case authentication(String)
    case permissionDenied(String)
    case modelNotFound(String)
    case badRequest(String)
    case requestTooLarge
    case rateLimited(retryAfter: Duration?)
    /// The account has no credit left (OpenAI reports this as a rate limit, but waiting doesn't help).
    case quotaExceeded(String)
    case overloaded
    case server(status: Int, message: String)
    case network(String)
    /// No route to the internet at all (retrying immediately can't help).
    case offline
    /// Nothing answers at the server's address (Ollama isn't running). The associated value is the host.
    case unreachable(String)
    case timedOut
    /// The response wasn't what the API documents.
    case invalidResponse(String)
    /// An `error` event arrived inside an otherwise healthy stream.
    case stream(type: String, message: String)
    /// The stream ended before the message was complete.
    case incompleteStream
    /// The local server doesn't have this model. The associated value is its name.
    case modelNotInstalled(String)
    /// The model can't call tools, which Voxa can't work without. The associated value is its name.
    case modelCannotUseTools(String)
    /// No model has been chosen yet (Ollama).
    case missingModel

    /// Whether trying the same request again can help. Never retried after a side effect: nothing runs until a full
    /// message has arrived, so a failed model call is always safe to repeat.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .network, .timedOut, .incompleteStream: true
        case .stream(let type, _): ["overloaded_error", "api_error", "rate_limit_error", "server_error"].contains(type)
        case .missingAPIKey, .authentication, .permissionDenied, .modelNotFound, .badRequest, .requestTooLarge,
            .invalidResponse, .offline, .quotaExceeded, .unreachable, .modelNotInstalled, .modelCannotUseTools,
            .missingModel:
            false
        }
    }

    /// The server's requested wait before a retry, when it gave one.
    var retryAfter: Duration? {
        if case .rateLimited(let retryAfter) = self { retryAfter } else { nil }
    }

    /// Classifies a transport failure.
    static func from(transport error: URLError) -> LLMError {
        switch error.code {
        case .timedOut:
            .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            .offline
        default:
            .network(error.localizedDescription)
        }
    }

    /// Maps an HTTP status and error body to an error.
    static func from(status: Int, type: String?, message: String, retryAfter: Duration?) -> LLMError {
        switch status {
        case 400: .badRequest(message)
        case 401: .authentication(message)
        case 403: .permissionDenied(message)
        case 404: .modelNotFound(message)
        case 413: .requestTooLarge
        case 429: .rateLimited(retryAfter: retryAfter)
        case 529: .overloaded
        case 500...599: type == "overloaded_error" ? .overloaded : .server(status: status, message: message)
        default: .invalidResponse("HTTP \(status): \(message)")
        }
    }
}

/// An `LLMError` that knows which service it came from, so the wording can name it ("OpenAI is busy", "Ollama isn't
/// running"). The routing client adds this; the individual clients throw plain `LLMError`s.
public struct ProviderFailure: Error, Sendable, Equatable {
    public var provider: ModelProvider
    public var error: LLMError

    public init(provider: ModelProvider, error: LLMError) {
        self.provider = provider
        self.error = error
    }
}

extension ProviderFailure: UserFacingConvertible {
    public var userFacing: UserFacingError { error.userFacing(for: provider) }
}

extension LLMError: UserFacingConvertible {
    /// Worded for Claude, the original provider.
    public var userFacing: UserFacingError { userFacing(for: .anthropic) }

    public func userFacing(for provider: ModelProvider) -> UserFacingError {
        switch provider {
        case .anthropic: anthropicWording
        case .openAI: openAIWording
        case .ollama: ollamaWording
        }
    }

    // MARK: Claude

    private var anthropicWording: UserFacingError {
        switch self {
        case .missingAPIKey:
            UserFacingError(
                title: L10n.LLM.missingKeyTitle, detail: L10n.LLM.missingKeyDetail, recovery: .openModelSettings
            )
        case .authentication:
            UserFacingError(title: L10n.LLM.authTitle, detail: L10n.LLM.authDetail, recovery: .openModelSettings)
        case .permissionDenied(let message):
            UserFacingError(title: L10n.LLM.permissionTitle, detail: message, recovery: .openModelSettings)
        case .modelNotFound:
            UserFacingError(title: L10n.LLM.modelTitle, detail: L10n.LLM.modelDetail, recovery: .openModelSettings)
        case .badRequest(let message):
            UserFacingError(title: L10n.LLM.badRequestTitle, detail: message)
        case .requestTooLarge:
            UserFacingError(title: L10n.LLM.tooLargeTitle, detail: L10n.LLM.tooLargeDetail)
        case .rateLimited:
            UserFacingError(title: L10n.LLM.rateLimitTitle, detail: L10n.LLM.rateLimitDetail)
        case .overloaded, .server:
            UserFacingError(title: L10n.LLM.busyTitle, detail: L10n.LLM.busyDetail)
        case .network(let reason):
            UserFacingError(title: L10n.LLM.offlineTitle, detail: L10n.LLM.offlineDetail(reason))
        case .offline:
            UserFacingError(title: L10n.LLM.offlineTitle, detail: L10n.LLM.offlineDetail("no internet connection"))
        case .timedOut:
            UserFacingError(title: L10n.LLM.timeoutTitle, detail: L10n.LLM.timeoutDetail)
        case .invalidResponse, .stream, .incompleteStream:
            UserFacingError(title: L10n.LLM.cutOffTitle, detail: L10n.LLM.cutOffDetail)
        case .quotaExceeded(let message):
            UserFacingError(title: L10n.LLMFailure.openAIQuotaTitle, detail: message)
        case .unreachable(let host):
            UserFacingError(title: L10n.LLM.offlineTitle, detail: L10n.LLM.offlineDetail(host))
        case .modelNotInstalled(let name), .modelCannotUseTools(let name):
            UserFacingError(title: L10n.LLM.modelTitle, detail: name, recovery: .openModelSettings)
        case .missingModel:
            UserFacingError(title: L10n.LLM.modelTitle, detail: L10n.LLM.modelDetail, recovery: .openModelSettings)
        }
    }

    // MARK: OpenAI

    private var openAIWording: UserFacingError {
        switch self {
        case .missingAPIKey:
            UserFacingError(
                title: L10n.LLMFailure.openAIMissingKeyTitle, detail: L10n.LLM.missingKeyDetail, recovery: .openModelSettings
            )
        case .authentication:
            UserFacingError(
                title: L10n.LLMFailure.openAIAuthTitle, detail: L10n.LLMFailure.openAIAuthDetail, recovery: .openModelSettings
            )
        case .badRequest(let message):
            UserFacingError(title: L10n.LLMFailure.openAIBadRequestTitle, detail: message)
        case .rateLimited:
            UserFacingError(title: L10n.LLMFailure.openAIRateLimitTitle, detail: L10n.LLM.rateLimitDetail)
        case .quotaExceeded:
            UserFacingError(title: L10n.LLMFailure.openAIQuotaTitle, detail: L10n.LLMFailure.openAIQuotaDetail)
        case .overloaded, .server:
            UserFacingError(title: L10n.LLMFailure.openAIBusyTitle, detail: L10n.LLM.busyDetail)
        case .network(let reason):
            UserFacingError(title: L10n.LLMFailure.openAIOfflineTitle, detail: L10n.LLM.offlineDetail(reason))
        case .offline:
            UserFacingError(title: L10n.LLMFailure.openAIOfflineTitle, detail: L10n.LLM.offlineDetail("no internet connection"))
        case .unreachable(let host):
            UserFacingError(title: L10n.LLMFailure.openAIOfflineTitle, detail: L10n.LLM.offlineDetail(host))
        case .timedOut:
            UserFacingError(title: L10n.LLMFailure.openAITimeoutTitle, detail: L10n.LLM.timeoutDetail)
        case .invalidResponse, .stream, .incompleteStream:
            UserFacingError(title: L10n.LLMFailure.openAICutOffTitle, detail: L10n.LLM.cutOffDetail)
        case .permissionDenied, .modelNotFound, .requestTooLarge, .modelNotInstalled, .modelCannotUseTools, .missingModel:
            anthropicWording
        }
    }

    // MARK: Ollama

    private var ollamaWording: UserFacingError {
        switch self {
        case .unreachable, .offline:
            UserFacingError(
                title: L10n.LLMFailure.ollamaNotRunningTitle, detail: L10n.LLMFailure.ollamaNotRunningDetail, recovery: .openOllama
            )
        case .network(let reason):
            UserFacingError(
                title: L10n.LLMFailure.ollamaNotRunningTitle,
                detail: L10n.LLMFailure.ollamaNotRunningDetail + " (\(reason))",
                recovery: .openOllama
            )
        case .missingModel:
            UserFacingError(
                title: L10n.LLMFailure.ollamaMissingModelTitle,
                detail: L10n.LLMFailure.ollamaMissingModelDetail,
                recovery: .openModelSettings
            )
        case .modelNotInstalled(let name), .modelNotFound(let name):
            UserFacingError(
                title: L10n.LLMFailure.ollamaModelNotInstalledTitle,
                detail: L10n.LLMFailure.ollamaModelNotInstalledDetail(name),
                recovery: .openModelSettings
            )
        case .modelCannotUseTools(let name):
            UserFacingError(
                title: L10n.LLMFailure.ollamaNoToolsTitle,
                detail: L10n.LLMFailure.ollamaNoToolsDetail(name),
                recovery: .openModelSettings
            )
        case .badRequest(let message):
            UserFacingError(title: L10n.LLMFailure.ollamaBadRequestTitle, detail: message)
        case .server(_, let message), .stream(_, let message):
            UserFacingError(
                title: L10n.LLMFailure.ollamaProblemTitle,
                detail: message.isEmpty ? L10n.LLMFailure.ollamaProblemDetail : message
            )
        case .overloaded:
            UserFacingError(title: L10n.LLMFailure.ollamaProblemTitle, detail: L10n.LLMFailure.ollamaProblemDetail)
        case .timedOut:
            UserFacingError(title: L10n.LLMFailure.ollamaTimeoutTitle, detail: L10n.LLMFailure.ollamaTimeoutDetail)
        case .invalidResponse, .incompleteStream:
            UserFacingError(title: L10n.LLMFailure.ollamaCutOffTitle, detail: L10n.LLM.cutOffDetail)
        case .missingAPIKey, .authentication, .permissionDenied, .requestTooLarge, .rateLimited, .quotaExceeded:
            anthropicWording
        }
    }
}
