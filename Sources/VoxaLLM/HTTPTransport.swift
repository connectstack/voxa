import Foundation

public struct HTTPResponseHead: Sendable, Equatable {
    public var statusCode: Int
    /// Header names are lowercased.
    public var headers: [String: String]

    public init(statusCode: Int, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Sends a request and streams the response body. A protocol so the client's retry, error and streaming logic is tested with
/// scripted responses and never touches the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>)
}

/// Answers a redirect with the redirect itself instead of following it. The Anthropic API never redirects, and URLSession
/// keeps custom headers such as `x-api-key` on a redirect to another host, so following one could hand the key to it.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// The production transport: `URLSession` with no disk cache or cookies, so nothing about a request outlives it.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    /// - Parameters:
    ///   - idleTimeout: Time allowed *between* packets. A hosted API's periodic pings keep a healthy connection well inside
    ///     it, so a longer silence means the connection is stuck, and a voice assistant should retry rather than wait a
    ///     minute. A local model may send nothing while it loads, so Ollama's transport allows much longer.
    ///   - totalTimeout: Time allowed for the whole response.
    public static func makeSession(idleTimeout: TimeInterval = 30, totalTimeout: TimeInterval = 300) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = totalTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func send(
        _ request: URLRequest
    ) async throws -> (head: HTTPResponseHead, body: AsyncThrowingStream<Data, any Error>) {
        let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("the response was not HTTP")
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }

        // Re-chunk the byte sequence at line boundaries so the consumer sees a sequence of `Data` blocks.
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                do {
                    var chunk = Data()
                    chunk.reserveCapacity(4_096)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count >= 4_096 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Cancelling the consumer cancels the byte iteration, which cancels the underlying URLSession task.
            continuation.onTermination = { _ in task.cancel() }
        }
        return (HTTPResponseHead(statusCode: http.statusCode, headers: headers), body)
    }
}
