import Foundation
import VoxaCore

// MARK: - Reading a response

/// Turns response bytes into stream events. One instance per attempt, because it holds parsing state.
protocol LLMStreamDecoder {
    mutating func push(_ chunk: Data) throws -> [LLMStreamEvent]
    /// The body ended: flush whatever is still buffered.
    mutating func finish() throws -> [LLMStreamEvent]
    /// The response ended properly, i.e. its own "done" marker arrived. A body that just stops is a dropped connection.
    var isComplete: Bool { get }
}

/// Reads one protocol's Server-Sent Events into stream events.
protocol SSETranslating {
    mutating func translate(_ event: SSEEvent) throws -> [LLMStreamEvent]
    var isComplete: Bool { get }
}

/// Reads one protocol's newline-delimited JSON (one object per line) into stream events.
protocol JSONLineTranslating {
    mutating func translate(_ line: JSONValue) throws -> [LLMStreamEvent]
    var isComplete: Bool { get }
}

struct SSEStreamDecoder<Translator: SSETranslating>: LLMStreamDecoder {
    private var splitter = LineSplitter()
    private var parser = SSEParser()
    private var translator: Translator

    init(_ translator: Translator) {
        self.translator = translator
    }

    var isComplete: Bool { translator.isComplete }

    mutating func push(_ chunk: Data) throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for line in splitter.push(chunk) {
            if let sse = parser.feed(line: line) { events += try translator.translate(sse) }
        }
        return events
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        if let trailing = splitter.finish(), let sse = parser.feed(line: trailing) { events += try translator.translate(sse) }
        if let sse = parser.finish() { events += try translator.translate(sse) }
        return events
    }
}

struct JSONLineStreamDecoder<Translator: JSONLineTranslating>: LLMStreamDecoder {
    private var splitter = LineSplitter()
    private var translator: Translator

    init(_ translator: Translator) {
        self.translator = translator
    }

    var isComplete: Bool { translator.isComplete }

    mutating func push(_ chunk: Data) throws -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = []
        for line in splitter.push(chunk) {
            events += try translate(line)
        }
        return events
    }

    mutating func finish() throws -> [LLMStreamEvent] {
        guard let trailing = splitter.finish() else { return [] }
        return try translate(trailing)
    }

    private mutating func translate(_ line: String) throws -> [LLMStreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONValue.parse(trimmed) else { throw LLMError.invalidResponse("unreadable line in the stream") }
        return try translator.translate(json)
    }
}

// MARK: - One wire protocol

/// Everything that differs between Claude's, OpenAI's and Ollama's APIs: what to send and how to read the answer. The engine
/// supplies retries, cancellation, error handling and streaming. One session serves one call to `stream`, so it may keep state
/// across attempts (for example, that the server refused an optional parameter).
protocol LLMWireSession: AnyObject, Sendable {
    /// What the log says about a request. Never the content of the conversation.
    var logDescription: String { get }
    /// Builds the request for the next attempt. Errors (a missing key, say) are handled like any other failure.
    func makeRequest() async throws -> URLRequest
    func makeDecoder() -> any LLMStreamDecoder
    /// Turns a non-200 response into an error.
    func mapError(head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) async -> LLMError
    /// Classifies a failure that isn't already an `LLMError`.
    func classify(_ error: any Error) -> LLMError
    /// Called when an attempt fails. Return true to repeat at once with a changed request (for example without an optional
    /// parameter the server rejected), which doesn't count as a retry.
    func adapt(to failure: LLMError) -> Bool
}

extension LLMWireSession {
    func classify(_ error: any Error) -> LLMError {
        if let llm = error as? LLMError { return llm }
        if let url = error as? URLError { return .from(transport: url) }
        return .network(error.localizedDescription)
    }

    func adapt(to failure: LLMError) -> Bool { false }
}

// MARK: - The loop

/// Runs a streamed request with the behavior every provider needs.
///
/// - Retries: rate limits, server errors, dropped connections and error events inside a stream are retried with backoff,
///   honoring `retry-after`. That is safe because nothing runs until a *complete* message has arrived. If events had already
///   been delivered, `.restarted` tells the consumer to discard them.
/// - Cancellation: cancelling the consuming task cancels the network request.
struct StreamingEngine: Sendable {
    let transport: any HTTPTransport
    let retryPolicy: RetryPolicy
    let clock: any Clock<Duration>

    func run(
        _ session: any LLMWireSession,
        into continuation: AsyncThrowingStream<LLMStreamEvent, any Error>.Continuation
    ) async throws {
        var attempt = 1

        while true {
            var deliveredEvents = false
            do {
                try Task.checkCancellation()
                let urlRequest = try await session.makeRequest()
                Log.llm.info("\(session.logDescription, privacy: .public), attempt \(attempt)")

                let (head, body) = try await transport.send(urlRequest)
                guard head.statusCode == 200 else {
                    throw await session.mapError(head: head, body: body)
                }

                var decoder = session.makeDecoder()
                func deliver(_ events: [LLMStreamEvent]) {
                    for event in events { continuation.yield(event) }
                    if !events.isEmpty { deliveredEvents = true }
                }
                for try await chunk in body {
                    try Task.checkCancellation()
                    deliver(try decoder.push(chunk))
                }
                deliver(try decoder.finish())

                guard decoder.isComplete else { throw LLMError.incompleteStream }
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let failure = session.classify(error)

                if session.adapt(to: failure) { continue }

                guard failure.isRetryable, attempt < retryPolicy.maxAttempts else { throw failure }
                let wait = retryPolicy.delay(afterAttempt: attempt, retryAfter: failure.retryAfter)
                Log.llm.notice(
                    "request failed (\(String(describing: failure), privacy: .public)); retrying in \(wait.description, privacy: .public)"
                )
                try await clock.sleep(for: wait)
                attempt += 1
                if deliveredEvents { continuation.yield(.restarted(attempt: attempt)) }
            }
        }
    }

    /// Wraps `run` as the stream `LLMClient.stream` returns.
    func stream(_ session: any LLMWireSession) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(session, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Where a request may go

enum EndpointPolicy {
    /// Where an API key may be sent: `https` anywhere, or `http` to the loopback interface (a local test server). Anything
    /// else could hand the key to whoever runs that host, so a bad setting must never be able to do it.
    static func isAcceptableForKey(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && isLoopback(host)
    }

    /// Where a server that takes no key may be: `http` or `https`, on this Mac or another machine the user names (Ollama on a
    /// home server, say). Nothing secret is sent, but the conversation is, so the address is the user's own choice.
    static func isAcceptableForKeylessServer(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }
}
