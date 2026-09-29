import Foundation
import os
import VoxaCore

/// Models served by Ollama, over its native chat API, streaming one JSON object per line.
///
/// Retries, cancellation and stream reading are shared with the other providers (`StreamingEngine`). What is specific here is
/// the request (`OllamaRequestBuilder`), the stream (`OllamaChatTranslator`), and the errors: a server that isn't running, a
/// model that isn't installed, a model that can't call tools.
///
/// Nothing secret is sent. By default the server is on this Mac, so a conversation with a local model never leaves it.
public struct OllamaClient: LLMClient {
    public static let defaultBaseURL = URL(string: AppSettings.defaultOllamaBaseURL)!

    /// A local model gets a generous pause for loading before it says its first word, and few retries: the failures that
    /// matter (not running, not installed) don't get better by waiting.
    public static let retryPolicy = RetryPolicy(
        maxAttempts: 2, baseDelay: .milliseconds(800), maxDelay: .seconds(4), jitter: 0.2, maxRetryAfter: .seconds(20)
    )

    private let baseURL: URL
    private let engine: StreamingEngine
    private let discovery: any OllamaDiscovering
    private let capabilities = CapabilityCache()

    public init(
        transport: any HTTPTransport = URLSessionTransport(session: URLSessionTransport.makeSession(idleTimeout: 180, totalTimeout: 900)),
        baseURL: URL = OllamaClient.defaultBaseURL,
        retryPolicy: RetryPolicy = OllamaClient.retryPolicy,
        clock: any Clock<Duration> = ContinuousClock(),
        discovery: (any OllamaDiscovering)? = nil
    ) {
        self.baseURL = Self.normalized(baseURL)
        self.engine = StreamingEngine(transport: transport, retryPolicy: retryPolicy, clock: clock)
        self.discovery = discovery ?? OllamaDiscovery(transport: transport)
    }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        let address = request.endpoint.flatMap { EndpointPolicy.isAcceptableForKeylessServer($0) ? Self.normalized($0) : nil } ?? baseURL
        return engine.stream(
            OllamaSession(request: request, builder: OllamaRequestBuilder(baseURL: address), discovery: discovery, cache: capabilities)
        )
    }

    /// An address typed in Settings as a usable server URL: `http` or `https`, with a host, cleaned up. Nil if it can't be one.
    public static func address(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            url.host?.isEmpty == false
        else { return nil }
        return normalized(url)
    }

    /// The server's address without a trailing slash or the API path someone may have pasted with it (`/api`, `/v1`).
    public static func normalized(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        for suffix in ["/api/chat", "/api", "/v1"] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        return URL(string: text) ?? url
    }

    // MARK: Errors

    /// A failure to reach the server, worded as what it means for Ollama: nothing is listening.
    static func classify(_ error: URLError, host: String) -> LLMError {
        switch error.code {
        case .networkConnectionLost:
            // A connection dropped mid-answer is retried.
            return .network(error.localizedDescription)
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
            // Nothing is there to retry against.
            return .unreachable(host)
        case .timedOut:
            return .timedOut
        default:
            return .network(error.localizedDescription)
        }
    }

    /// Maps an error response. Ollama's errors are `{"error": "message"}`.
    static func mapped(status: Int, data: Data, model: String) -> LLMError {
        let json = try? JSONValue.parse(data)
        let message = json?["error"]?.stringValue ?? "Ollama returned HTTP \(status)."
        let lowered = message.lowercased()

        switch status {
        case 404:
            return .modelNotInstalled(model)
        case 400 where lowered.contains("does not support tools"):
            return .modelCannotUseTools(model)
        case 400:
            return .badRequest(message)
        case 401, 403:
            return .authentication(message)
        case 429:
            return .rateLimited(retryAfter: nil)
        default:
            return LLMError.from(status: status, type: nil, message: message, retryAfter: nil)
        }
    }

    static func mentionsThinking(_ message: String) -> Bool {
        message.lowercased().contains("think")
    }
}

/// Remembers what each model can do for a few minutes, so a command doesn't ask the server the same question twice.
final class CapabilityCache: Sendable {
    private struct Entry {
        var details: OllamaModelDetails
        var fetchedAt: Date
    }

    private let entries = OSAllocatedUnfairLock(initialState: [String: Entry]())
    private let lifetime: TimeInterval = 600

    func details(for key: String) -> OllamaModelDetails? {
        entries.withLock { entries in
            guard let entry = entries[key], Date().timeIntervalSince(entry.fetchedAt) < lifetime else { return nil }
            return entry.details
        }
    }

    func store(_ details: OllamaModelDetails, for key: String) {
        entries.withLock { $0[key] = Entry(details: details, fetchedAt: Date()) }
    }
}

/// One call to Ollama: the request, and what to do when the server rejects the optional `think` setting.
private final class OllamaSession: LLMWireSession, @unchecked Sendable {
    private let request: LLMRequest
    private let builder: OllamaRequestBuilder
    private let discovery: any OllamaDiscovering
    private let cache: CapabilityCache
    private var sendThink = true

    init(request: LLMRequest, builder: OllamaRequestBuilder, discovery: any OllamaDiscovering, cache: CapabilityCache) {
        self.request = request
        self.builder = builder
        self.discovery = discovery
        self.cache = cache
    }

    var logDescription: String { "request to Ollama model \(request.model): \(request.messages.count) messages" }

    /// What the model is told when it is sent a picture it can't see: an honest note, so it can say so instead of failing.
    static let noVisionNote = "[A picture was taken, but this model can't see images. Tell the user that.]"

    func makeRequest() async throws -> URLRequest {
        guard !request.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw LLMError.missingModel }
        let think = sendThink ? await thinkSetting() : nil
        return try builder.urlRequest(for: await withoutUnusablePictures(request), think: think)
    }

    /// A model without vision would answer a picture with an error. When the server says it can't see, the pictures are left out
    /// and replaced by a note; when it can't be asked, they are sent as they are.
    private func withoutUnusablePictures(_ request: LLMRequest) async -> LLMRequest {
        guard request.messages.contains(where: \.containsImages), let details = await modelDetails(),
            !details.capabilities.contains("vision")
        else { return request }
        var edited = request
        edited.messages = request.messages.map { $0.replacingImages(with: Self.noVisionNote) }
        return edited
    }

    /// What the server says about the model, remembered for a few minutes.
    private func modelDetails() async -> OllamaModelDetails? {
        let key = "\(builder.baseURL.absoluteString)|\(request.model)"
        if let cached = cache.details(for: key) { return cached }
        guard let fetched = try? await discovery.details(of: request.model, at: builder.baseURL) else { return nil }
        cache.store(fetched, for: key)
        return fetched
    }

    func makeDecoder() -> any LLMStreamDecoder {
        JSONLineStreamDecoder(OllamaChatTranslator())
    }

    func mapError(head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) async -> LLMError {
        OllamaClient.mapped(status: head.statusCode, data: await readBounded(body), model: request.model)
    }

    func classify(_ error: any Error) -> LLMError {
        if let llm = error as? LLMError { return llm }
        if let url = error as? URLError { return OllamaClient.classify(url, host: builder.baseURL.host ?? builder.baseURL.absoluteString) }
        return .network(error.localizedDescription)
    }

    /// The server didn't like the thinking setting (a model whose descriptor was missing or wrong): ask again without it.
    func adapt(to failure: LLMError) -> Bool {
        guard sendThink, case .badRequest(let message) = failure, OllamaClient.mentionsThinking(message) else { return false }
        Log.llm.notice("the model doesn't take a thinking setting; continuing without it")
        sendThink = false
        return true
    }

    /// How to ask this model to think, given the user's setting. A quick setting turns thinking off where the model allows it,
    /// since a voice command shouldn't wait on a long chain of thought; otherwise the model's own default applies.
    private func thinkSetting() async -> OllamaThink? {
        guard let effort = request.effort, let details = await modelDetails() else { return nil }

        switch details.thinking {
        case .unsupported, .always:
            return nil
        case .toggle:
            return effort == .low ? .off : nil
        case .levels(let levels):
            return levels.contains(effort.rawValue) ? .level(effort.rawValue) : nil
        }
    }
}
