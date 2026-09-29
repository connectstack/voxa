import Foundation
import VoxaCore

/// OpenAI's models over the Responses API, streaming Server-Sent Events.
///
/// Retries, cancellation and stream reading are shared with the other providers (`StreamingEngine`). What is specific here is
/// the request (`OpenAIRequestBuilder`), the events (`OpenAIResponsesTranslator`) and the errors.
///
/// Secrets: the key is fetched per request and only ever placed in the `Authorization` header. It is never logged.
public struct OpenAIClient: LLMClient {
    public static let officialBaseURL = URL(string: AppSettings.defaultOpenAIBaseURL)!

    /// A reasoning model can go quiet while it thinks, before its first word, so the connection gets longer to stay silent than
    /// the default before it is given up on.
    public static var defaultTransport: any HTTPTransport {
        URLSessionTransport(session: URLSessionTransport.makeSession(idleTimeout: 60))
    }

    private let keys: any APIKeyProviding
    private let baseURL: URL
    private let engine: StreamingEngine

    /// - Parameter baseURL: Must be `https`, or plain `http` to the loopback interface (a local test server); anything else
    ///   falls back to OpenAI's own address, so a bad setting can never send the key to an arbitrary host.
    public init(
        keys: any APIKeyProviding,
        transport: any HTTPTransport = OpenAIClient.defaultTransport,
        baseURL: URL = OpenAIClient.officialBaseURL,
        retryPolicy: RetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.keys = keys
        self.baseURL = Self.isAcceptable(baseURL) ? baseURL : Self.officialBaseURL
        self.engine = StreamingEngine(transport: transport, retryPolicy: retryPolicy, clock: clock)
    }

    static func isAcceptable(_ url: URL) -> Bool {
        EndpointPolicy.isAcceptableForKey(url)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        // The request may name an address (from Settings); it gets the same vetting as the one given at creation.
        let address = request.endpoint.flatMap { Self.isAcceptable($0) ? $0 : nil } ?? baseURL
        return engine.stream(OpenAISession(request: request, keys: keys, builder: OpenAIRequestBuilder(baseURL: address)))
    }

    // MARK: Errors

    /// Maps an error's `code` (and `type`) to an error. Shared by HTTP errors and errors inside a stream.
    static func mapped(code: String, type: String?, message: String, status: Int? = nil) -> LLMError {
        switch code {
        case "insufficient_quota": return .quotaExceeded(message)
        case "model_not_found": return .modelNotFound(message)
        case "context_length_exceeded": return .requestTooLarge
        case "invalid_api_key", "invalid_organization", "invalid_project": return .authentication(message)
        case "rate_limit_exceeded": return .rateLimited(retryAfter: nil)
        case "server_error", "overloaded", "service_unavailable", "internal_error": return .stream(type: "server_error", message: message)
        default: break
        }
        if let status { return LLMError.from(status: status, type: type, message: message, retryAfter: nil) }
        return .stream(type: type ?? code, message: message)
    }

    /// Reads an error response's body (bounded) and maps it. Never throws: a body that can't be read still maps by status.
    static func error(from head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) async -> LLMError {
        let data = await readBounded(body)
        let json = try? JSONValue.parse(data)
        let error = json?["error"]
        let message = error?["message"]?.stringValue ?? "The API returned HTTP \(head.statusCode)."
        let retryAfter = head.headers["retry-after"].flatMap(Double.init).map { Duration.seconds($0) }

        let mapped = mapped(
            code: error?["code"]?.stringValue ?? "", type: error?["type"]?.stringValue, message: message, status: head.statusCode
        )
        // A rate limit that names a wait keeps it.
        if case .rateLimited = mapped { return .rateLimited(retryAfter: retryAfter) }
        return mapped
    }

    /// Whether an error says the request's `reasoning` parameter was the problem (a model that doesn't take it).
    static func mentionsReasoning(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("reasoning") || lowered.contains("effort")
    }

    /// Whether an error says the `phase` label on an assistant message was the problem (a model or server that doesn't know it).
    static func mentionsPhase(_ message: String) -> Bool {
        message.lowercased().contains("phase")
    }
}

/// One call to OpenAI: the request, and what to do when the server rejects an optional part of it (`reasoning`, `phase`).
private final class OpenAISession: LLMWireSession, @unchecked Sendable {
    private let request: LLMRequest
    private let keys: any APIKeyProviding
    private let builder: OpenAIRequestBuilder
    private var includeReasoning = true
    private var includePhase = true

    init(request: LLMRequest, keys: any APIKeyProviding, builder: OpenAIRequestBuilder) {
        self.request = request
        self.keys = keys
        self.builder = builder
    }

    var logDescription: String { "request to \(request.model): \(request.messages.count) messages" }

    func makeRequest() async throws -> URLRequest {
        let apiKey = try await keys.apiKey()
        return try builder.urlRequest(
            for: request, apiKey: apiKey, includeReasoning: includeReasoning, includePhase: includePhase
        )
    }

    func makeDecoder() -> any LLMStreamDecoder {
        SSEStreamDecoder(OpenAIResponsesTranslator())
    }

    func mapError(head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) async -> LLMError {
        await OpenAIClient.error(from: head, body: body)
    }

    /// The model doesn't take `reasoning` (a chat model, or one newer than Voxa's list) or doesn't know `phase`: send the
    /// request without whichever the server named.
    func adapt(to failure: LLMError) -> Bool {
        guard case .badRequest(let message) = failure else { return false }
        if includePhase, OpenAIClient.mentionsPhase(message) {
            Log.llm.notice("the server doesn't take a message phase; continuing without it")
            includePhase = false
            return true
        }
        if includeReasoning, request.effort != nil, OpenAIClient.mentionsReasoning(message) {
            Log.llm.notice("the model doesn't take a reasoning setting; continuing without it")
            includeReasoning = false
            return true
        }
        return false
    }
}
