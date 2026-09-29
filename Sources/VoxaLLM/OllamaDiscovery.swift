import Foundation
import VoxaCore

/// A model installed on an Ollama server.
public struct OllamaModel: Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var sizeBytes: Int64
    public var parameterSize: String?
    public var family: String?
    public var quantization: String?
    /// Runs on Ollama's own servers rather than on this Mac: what you say still leaves the machine.
    public var isCloud: Bool

    public var id: String { name }

    public init(
        name: String,
        sizeBytes: Int64 = 0,
        parameterSize: String? = nil,
        family: String? = nil,
        quantization: String? = nil,
        isCloud: Bool = false
    ) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.family = family
        self.quantization = quantization
        self.isCloud = isCloud
    }
}

/// What one model can do, from `POST /api/show`.
public struct OllamaModelDetails: Sendable, Equatable {
    /// How the model handles the `think` setting.
    public enum Thinking: Sendable, Equatable {
        /// The model doesn't think.
        case unsupported
        /// It can be switched on or off.
        case toggle
        /// It takes named levels.
        case levels([String])
        /// It always thinks.
        case always
    }

    /// For example `completion`, `tools`, `thinking`, `vision`.
    public var capabilities: Set<String>
    public var thinking: Thinking
    public var contextLength: Int?

    public var supportsTools: Bool { capabilities.contains("tools") }

    public init(capabilities: Set<String> = [], thinking: Thinking = .unsupported, contextLength: Int? = nil) {
        self.capabilities = capabilities
        self.thinking = thinking
        self.contextLength = contextLength
    }
}

/// Asks an Ollama server what it has. Used by Settings (to list models and show what each can do) and by the client (to
/// decide how to ask a thinking model to think).
public protocol OllamaDiscovering: Sendable {
    func version(at baseURL: URL) async throws -> String
    func models(at baseURL: URL) async throws -> [OllamaModel]
    func details(of model: String, at baseURL: URL) async throws -> OllamaModelDetails
}

public struct OllamaDiscovery: OllamaDiscovering {
    private let transport: any HTTPTransport
    private let timeout: TimeInterval

    public init(
        transport: any HTTPTransport = URLSessionTransport(
            session: URLSessionTransport.makeSession(idleTimeout: 10, totalTimeout: 30)
        ),
        timeout: TimeInterval = 5
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func version(at baseURL: URL) async throws -> String {
        let json = try await get("api/version", at: baseURL)
        return json["version"]?.stringValue ?? "unknown"
    }

    public func models(at baseURL: URL) async throws -> [OllamaModel] {
        let json = try await get("api/tags", at: baseURL)
        return (json["models"]?.arrayValue ?? []).compactMap { entry -> OllamaModel? in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            let details = entry["details"]
            return OllamaModel(
                name: name,
                sizeBytes: Int64(entry["size"]?.doubleValue ?? 0),
                parameterSize: details?["parameter_size"]?.stringValue,
                family: details?["family"]?.stringValue,
                quantization: details?["quantization_level"]?.stringValue,
                isCloud: entry["remote_host"]?.stringValue != nil || entry["remote_model"]?.stringValue != nil
                    || name.hasSuffix(":cloud") || name.hasSuffix("-cloud")
            )
        }
    }

    public func details(of model: String, at baseURL: URL) async throws -> OllamaModelDetails {
        let json = try await send(path: "api/show", at: baseURL, body: ["model": .string(model)])
        let capabilities = Set((json["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue))

        return OllamaModelDetails(
            capabilities: capabilities,
            thinking: Self.thinking(from: json["thinking"], capabilities: capabilities),
            contextLength: Self.contextLength(in: json["model_info"])
        )
    }

    // MARK: Parsing

    /// Newer servers describe how a model thinks (`{"values": [false, true]}` or `{"values": ["low", "medium", "high"]}`); older
    /// ones only list `thinking` among the capabilities.
    static func thinking(from descriptor: JSONValue?, capabilities: Set<String>) -> OllamaModelDetails.Thinking {
        let values = descriptor?["values"]?.arrayValue ?? []
        let levels = values.compactMap(\.stringValue)
        if !levels.isEmpty { return .levels(levels) }
        if values.contains(false) { return .toggle }
        if !values.isEmpty { return .always }   // only `true`
        return capabilities.contains("thinking") ? .toggle : .unsupported
    }

    /// The model's own maximum context, stored under a key named for its family (`qwen3.context_length`).
    static func contextLength(in info: JSONValue?) -> Int? {
        info?.objectValue?.first { $0.key.hasSuffix(".context_length") }?.value.intValue
    }

    // MARK: Requests

    private func get(_ path: String, at baseURL: URL) async throws -> JSONValue {
        try await send(path: path, at: baseURL, body: nil)
    }

    private func send(path: String, at baseURL: URL, body: JSONValue?) async throws -> JSONValue {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try WireJSON.encode(body)
        }

        let head: HTTPResponseHead
        let stream: AsyncThrowingStream<Data, any Error>
        do {
            (head, stream) = try await transport.send(request)
        } catch let error as URLError {
            throw OllamaClient.classify(error, host: baseURL.host ?? baseURL.absoluteString)
        }
        let data = await readBounded(stream, limit: 4_000_000)
        guard head.statusCode == 200 else {
            throw OllamaClient.mapped(status: head.statusCode, data: data, model: body?["model"]?.stringValue ?? "")
        }
        guard let json = try? JSONValue.parse(data) else { throw LLMError.invalidResponse("unreadable reply from Ollama") }
        return json
    }
}
