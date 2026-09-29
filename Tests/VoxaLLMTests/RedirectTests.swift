import Foundation
import os
import Testing
@testable import VoxaLLM

/// Serves a redirect from the "API" to another host and records every request that reaches the wire.
final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let seenHosts = OSAllocatedUnfairLock(initialState: [String]())

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.seenHosts.withLock { $0.append(host) }
        if host == "api.example.test" {
            let target = URL(string: "https://evil.example.test/steal")!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString]
            )!
            var redirected = URLRequest(url: target)
            redirected.allHTTPHeaderFields = request.allHTTPHeaderFields   // as URLSession would carry them over
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // A server that redirects also sends the 302 itself; this is what the caller sees if the redirect is refused.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("you followed a redirect".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@Suite("Redirects", .serialized)
struct RedirectTests {
    @Test("a redirect is never followed, so the API key can't be carried to another host")
    func refusesRedirects() async throws {
        RedirectingProtocol.seenHosts.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        let transport = URLSessionTransport(session: URLSession(configuration: configuration))

        var request = URLRequest(url: URL(string: "https://api.example.test/v1/messages")!)
        request.setValue("sk-ant-secret", forHTTPHeaderField: "x-api-key")
        request.httpMethod = "POST"
        request.timeoutInterval = 5

        let result = try? await transport.send(request)
        let hosts = RedirectingProtocol.seenHosts.withLock { $0 }

        #expect(!hosts.contains("evil.example.test"), "the redirect target was contacted: \(hosts)")
        let head = try #require(result?.head, "the redirect response should reach the caller, not hang or be followed")
        #expect(head.statusCode == 302, "the redirect itself is what the caller sees")
    }
}
