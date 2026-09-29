import Foundation
import os
import VoxaCore
import VoxaLLM

/// An `HTTPTransport` that plays back scripted responses and records what it was asked to send.
public final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        /// Body bytes delivered in order.
        public var chunks: [Data]
        /// Thrown from the body stream after the chunks (a connection dropped mid-response).
        public var streamFailure: (any Error)?
        /// Thrown from `send` itself (the connection could not be made).
        public var sendFailure: (any Error)?
        /// Hold the body open after the chunks, until the consumer goes away.
        public var holdOpen: Bool

        public init(
            status: Int = 200,
            headers: [String: String] = [:],
            chunks: [Data] = [],
            streamFailure: (any Error)? = nil,
            sendFailure: (any Error)? = nil,
            holdOpen: Bool = false
        ) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
            self.streamFailure = streamFailure
            self.sendFailure = sendFailure
            self.holdOpen = holdOpen
        }

        /// A 200 streaming response made of the given SSE text, split into `chunkSize`-byte pieces (default: one piece).
        public static func stream(_ sse: String, chunkSize: Int? = nil, then failure: (any Error)? = nil) -> Response {
            Response(chunks: SSE.chunked(sse, size: chunkSize ?? Int.max), streamFailure: failure)
        }

        /// A JSON error response like the API's.
        public static func error(status: Int, type: String, message: String, headers: [String: String] = [:]) -> Response {
            let body = #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#
            return Response(status: status, headers: headers, chunks: [Data(body.utf8)])
        }
    }

    private struct State {
        var responses: [Response]
        var requests: [URLRequest] = []
        var terminatedStreams = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(_ responses: [Response]) {
        state = OSAllocatedUnfairLock(initialState: State(responses: responses))
    }

    public var requests: [URLRequest] { state.withLock { $0.requests } }
    public var requestCount: Int { state.withLock { $0.requests.count } }
    /// How many body streams ended because the consumer stopped early (cancellation).
    public var terminatedStreams: Int { state.withLock { $0.terminatedStreams } }

    /// The JSON body of request `index`.
    public func body(ofRequest index: Int) -> JSONValue? {
        guard let data = requests[safe: index]?.httpBody else { return nil }
        return try? JSONValue.parse(data)
    }

    public func send(
        _ request: URLRequest
    ) async throws -> (head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) {
        let response: Response = state.withLock { state in
            state.requests.append(request)
            return state.responses.isEmpty ? Response(status: 500) : state.responses.removeFirst()
        }
        if let failure = response.sendFailure { throw failure }

        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for chunk in response.chunks {
                    continuation.yield(chunk)
                    await Task.yield()
                }
                if let failure = response.streamFailure {
                    continuation.finish(throwing: failure)
                } else if response.holdOpen {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { [state] termination in
                if case .cancelled = termination { state.withLock { $0.terminatedStreams += 1 } }
                task.cancel()
            }
        }
        return (HTTPResponseHead(statusCode: response.status, headers: response.headers), body)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
