import Foundation
import VoxaCore

/// The Anthropic Messages API over `URLSession`, streaming Server-Sent Events.
///
/// Retries, cancellation and stream reading are shared with the other providers (`StreamingEngine`); what is specific to this
/// API is here: the request (`AnthropicRequestBuilder`), the events (`AnthropicEventDecoder`), the errors, and the optional
/// refusal-fallback parameter, which is dropped if the API rejects it.
///
/// Secrets: the key is fetched per request and only ever placed in the `x-api-key` header. It is never logged.
public struct AnthropicClient: LLMClient {
    public static let officialBaseURL = URL(string: "https://api.anthropic.com")!

    private let keys: any APIKeyProviding
    private let baseURL: URL
    private let engine: StreamingEngine

    /// - Parameter baseURL: Must be `https`, or plain `http` to the loopback interface (for a local test server). Anything
    ///   else falls back to Anthropic's own endpoint, so a bad setting can never send the key to an arbitrary host.
    public init(
        keys: any APIKeyProviding,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = AnthropicClient.officialBaseURL,
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
        engine.stream(AnthropicSession(request: request, keys: keys, builder: AnthropicRequestBuilder(baseURL: baseURL)))
    }

    // MARK: Errors

    static func mentionsFallback(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("fallback") || lowered.contains("anthropic-beta")
    }

    /// Reads an error response's body (bounded) and maps it. Never throws: a body that can't be read still maps by status.
    static func error(from head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) async -> LLMError {
        let data = await readBounded(body)
        let json = try? JSONValue.parse(data)
        let type = json?["error"]?["type"]?.stringValue
        let message = json?["error"]?["message"]?.stringValue ?? "The API returned HTTP \(head.statusCode)."
        let retryAfter = head.headers["retry-after"].flatMap(Double.init).map { Duration.seconds($0) }
        return LLMError.from(status: head.statusCode, type: type, message: message, retryAfter: retryAfter)
    }
}

/// Reads at most `limit` bytes of a response body (64 KB unless told otherwise), ignoring a failure part-way through.
func readBounded(_ body: AsyncThrowingStream<Data, any Error>, limit: Int = 65_536) async -> Data {
    var data = Data()
    do {
        for try await chunk in body {
            data.append(chunk)
            if data.count > limit { break }
        }
    } catch {
        // Fall through with whatever arrived.
    }
    return data
}

/// One call to Claude: the request, and what to do when the API rejects the optional fallback.
private final class AnthropicSession: LLMWireSession, @unchecked Sendable {
    private let request: LLMRequest
    private let keys: any APIKeyProviding
    private let builder: AnthropicRequestBuilder
    private var useFallback: Bool

    init(request: LLMRequest, keys: any APIKeyProviding, builder: AnthropicRequestBuilder) {
        self.request = request
        self.keys = keys
        self.builder = builder
        self.useFallback = builder.allowsRefusalFallback(for: request)
    }

    var logDescription: String { "request to \(request.model): \(request.messages.count) messages" }

    func makeRequest() async throws -> URLRequest {
        let apiKey = try await keys.apiKey()
        return try builder.urlRequest(for: request, apiKey: apiKey, useFallback: useFallback)
    }

    func makeDecoder() -> any LLMStreamDecoder {
        SSEStreamDecoder(AnthropicTranslator())
    }

    func mapError(head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) async -> LLMError {
        await AnthropicClient.error(from: head, body: body)
    }

    /// The API rejected the fallback opt-in (an org that isn't enabled for the beta, say): drop it and go on without, rather
    /// than failing every command.
    func adapt(to failure: LLMError) -> Bool {
        guard useFallback, case .badRequest(let message) = failure, AnthropicClient.mentionsFallback(message) else {
            return false
        }
        Log.llm.notice("refusal fallback was rejected; continuing without it")
        useFallback = false
        return true
    }
}

/// Claude's events map one to one.
private struct AnthropicTranslator: SSETranslating {
    private(set) var isComplete = false

    mutating func translate(_ event: SSEEvent) throws -> [LLMStreamEvent] {
        guard let decoded = try AnthropicEventDecoder.decode(event) else { return [] }
        if case .messageStop = decoded { isComplete = true }
        return [decoded]
    }
}
