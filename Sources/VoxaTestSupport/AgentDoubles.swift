import Foundation
import os
import VoxaAgent
import VoxaCore
import VoxaLLM

// MARK: - Scripted model

/// An `LLMClient` that plays back prepared turns, so the agent loop can be tested without a network or a real model.
/// It records every request, so tests can check exactly what the model would have been sent.
public final class ScriptedLLM: LLMClient, @unchecked Sendable {
    public enum Turn: Sendable {
        /// A complete response, delivered as the stream of events the API would send.
        case response(LLMResponse)
        /// Raw events, for streams a well-formed response can't express (malformed tool input, a dropped connection).
        case events([LLMStreamEvent], then: (any Error)? = nil)
        case failure(any Error)
        /// Keeps the stream open until the consumer cancels it.
        case hold
    }

    private struct State {
        var turns: [Turn]
        var requests: [LLMRequest] = []
        var cancelledStreams = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(_ turns: [Turn]) {
        state = OSAllocatedUnfairLock(initialState: State(turns: turns))
    }

    public var requests: [LLMRequest] { state.withLock { $0.requests } }
    public var requestCount: Int { state.withLock { $0.requests.count } }
    /// Streams that were torn down because their consumer went away, which is how a cancelled request shows up.
    public var cancelledStreams: Int { state.withLock { $0.cancelledStreams } }

    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        let turn: Turn? = state.withLock { state in
            state.requests.append(request)
            return state.turns.isEmpty ? nil : state.turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch turn {
            case .response(let response)?:
                for event in response.streamEvents() { continuation.yield(event) }
                continuation.finish()
            case .events(let events, let error)?:
                for event in events { continuation.yield(event) }
                continuation.finish(throwing: error)
            case .failure(let error)?:
                continuation.finish(throwing: error)
            case .hold?:
                continuation.onTermination = { [state] termination in
                    if case .cancelled = termination { state.withLock { $0.cancelledStreams += 1 } }
                }
            case nil:
                continuation.finish(throwing: LLMError.invalidResponse("ScriptedLLM ran out of turns"))
            }
        }
    }
}

extension LLMResponse {
    /// The events the API would stream for this response.
    public func streamEvents() -> [LLMStreamEvent] {
        var events: [LLMStreamEvent] = [.messageStart(id: id, model: model, usage: usage)]
        for (index, block) in content.enumerated() {
            switch block {
            case .text(let text):
                events += [
                    .blockStart(index: index, block: .text("")), .blockDelta(index: index, delta: .text(text)),
                    .blockStop(index: index),
                ]
            case .toolUse(let id, let name, let input):
                events += [
                    .blockStart(index: index, block: .toolUse(id: id, name: name)),
                    .blockDelta(index: index, delta: .inputJSON(input.serialized())),
                    .blockStop(index: index),
                ]
            case .raw(let json):
                events += [.blockStart(index: index, block: .other(json)), .blockStop(index: index)]
            case .toolResult:
                break
            }
        }
        events.append(.messageDelta(stopReason: stopReason, usage: usage))
        events.append(.messageStop)
        return events
    }

    /// The model answers in words and is done.
    public static func say(_ text: String) -> LLMResponse {
        LLMResponse(
            id: "msg_" + UUID().uuidString.prefix(8),
            model: "test",
            content: [.text(text)],
            stopReason: .endTurn
        )
    }

    /// The model calls one tool, optionally saying something first.
    public static func call(
        _ name: String,
        _ input: JSONValue = [:],
        id: String? = nil,
        saying text: String? = nil
    ) -> LLMResponse {
        calls([(name, input, id)], saying: text)
    }

    /// The model calls several tools in one turn.
    public static func calls(
        _ calls: [(name: String, input: JSONValue, id: String?)],
        saying text: String? = nil
    ) -> LLMResponse {
        var content: [ContentBlock] = []
        if let text { content.append(.text(text)) }
        for call in calls {
            content.append(
                .toolUse(id: call.id ?? "toolu_" + UUID().uuidString.prefix(8), name: call.name, input: call.input)
            )
        }
        return LLMResponse(
            id: "msg_" + UUID().uuidString.prefix(8),
            model: "test",
            content: content,
            stopReason: .toolUse
        )
    }

    public static func refusal(saying text: String? = nil, alsoCalling name: String? = nil) -> LLMResponse {
        var content: [ContentBlock] = []
        if let text { content.append(.text(text)) }
        if let name { content.append(.toolUse(id: "toolu_refused", name: name, input: [:])) }
        return LLMResponse(id: "msg_refusal", model: "test", content: content, stopReason: .refusal(category: nil))
    }
}

// MARK: - Tools

/// Counts what a stub tool actually ran with.
public final class ToolRecorder: Sendable {
    private let inputs = OSAllocatedUnfairLock(initialState: [JSONValue]())

    public init() {}

    public var executed: [JSONValue] { inputs.withLock { $0 } }
    public var count: Int { inputs.withLock { $0.count } }
    public var isEmpty: Bool { inputs.withLock { $0.isEmpty } }

    func record(_ input: JSONValue) {
        inputs.withLock { $0.append(input) }
    }
}

/// A tool whose risk, assessment and behavior are set by the test.
public struct StubTool: AgentTool {
    public let name: String
    public var summary: String
    public var inputSchema: JSONValue
    public var baselineRisk: RiskLevel
    public var requiredPermissions: Set<PermissionKind> = []
    public var assessment: @Sendable (JSONValue) throws -> ToolAssessment
    public var behavior: @Sendable (JSONValue) async throws -> ToolResult
    public let recorder = ToolRecorder()

    /// A tool whose assessment is the default one for its risk: a title, a summary and the arguments as a code row.
    public init(
        _ name: String,
        risk: RiskLevel = .readOnly,
        schema: JSONValue = Schema.object(["value": Schema.string("A value")]),
        run: @escaping @Sendable (JSONValue) async throws -> ToolResult = { _ in .text("ok") }
    ) {
        self.init(
            name,
            risk: risk,
            schema: schema,
            assess: { input in
                ToolAssessment(
                    risk: risk,
                    title: "Run \(name)",
                    summary: "Runs \(name) with \(input.serialized()).",
                    details: [DetailRow("Arguments", input.serialized(), style: .code)]
                )
            },
            run: run
        )
    }

    /// A tool that describes its own calls, as real tools do.
    public init(
        _ name: String,
        risk: RiskLevel,
        schema: JSONValue = Schema.object(["value": Schema.string("A value")]),
        assess: @escaping @Sendable (JSONValue) throws -> ToolAssessment,
        run: @escaping @Sendable (JSONValue) async throws -> ToolResult = { _ in .text("ok") }
    ) {
        self.name = name
        self.summary = "Stub tool \(name)."
        self.inputSchema = schema
        self.baselineRisk = risk
        self.assessment = assess
        self.behavior = run
    }

    public func assess(_ input: JSONValue) throws -> ToolAssessment {
        try assessment(input)
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult {
        recorder.record(input)
        return try await behavior(input)
    }
}

// MARK: - Permissions

/// Grants tool permissions as the test dictates, remembers what was asked, and can hold a "prompt" open.
public final class ScriptedToolPermissions: ToolPermissionGranting, @unchecked Sendable {
    private struct State {
        var statuses: [PermissionKind: PermissionStatus]
        var asked: [[PermissionKind]] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let gate: AsyncGate?

    /// - Parameters:
    ///   - statuses: What each permission's answer is; anything not listed is granted.
    ///   - gate: When set, every request waits for it to open, like a system prompt nobody has answered yet.
    public init(_ statuses: [PermissionKind: PermissionStatus] = [:], gate: AsyncGate? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(statuses: statuses))
        self.gate = gate
    }

    /// Every set of permissions the loop asked about, in order.
    public var asked: [[PermissionKind]] { state.withLock { $0.asked } }

    public func ensureGranted(_ kinds: [PermissionKind]) async -> UserFacingError? {
        state.withLock { $0.asked.append(kinds) }
        await gate?.wait()
        for kind in kinds {
            let status = state.withLock { $0.statuses[kind] } ?? .granted
            if !status.isGranted { return .permissionRequired(kind, status: status) }
        }
        return nil
    }
}

// MARK: - Confirmation and audit

/// Answers confirmation prompts from a script and remembers what it was asked.
public final class ScriptedConfirmations: ConfirmationProviding, @unchecked Sendable {
    public enum Answer: Sendable {
        case outcome(ConfirmationOutcome)
        /// Waits until `release()` is called (or the asking task is cancelled, which answers `.cancelled`).
        case waitForRelease(then: ConfirmationOutcome)
    }

    private struct State {
        var answers: [Answer]
        var prompts: [ConfirmationPrompt] = []
        var released = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(_ answers: [Answer] = []) {
        state = OSAllocatedUnfairLock(initialState: State(answers: answers))
    }

    public convenience init(_ outcomes: ConfirmationOutcome...) {
        self.init(outcomes.map(Answer.outcome))
    }

    public var prompts: [ConfirmationPrompt] { state.withLock { $0.prompts } }

    public func release() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.released = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    public func confirm(_ prompt: ConfirmationPrompt) async -> ConfirmationOutcome {
        let answer: Answer = state.withLock { state in
            state.prompts.append(prompt)
            return state.answers.isEmpty ? .outcome(.denied) : state.answers.removeFirst()
        }
        switch answer {
        case .outcome(let outcome):
            return outcome
        case .waitForRelease(let outcome):
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = state.withLock { state -> Bool in
                        if state.released { return true }
                        state.waiters.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                release()
            }
            return Task.isCancelled ? .cancelled : outcome
        }
    }
}

/// Keeps every audit entry in memory, and can be read back and cleared like the real trail.
public actor RecordingAuditLog: AuditLogging, AuditReading {
    public private(set) var entries: [AuditEntry] = []
    public private(set) var clearCount = 0
    /// Makes the next `clear()` throw, as a file that can't be deleted would.
    public var clearFailure: (any Error)?

    public init(_ entries: [AuditEntry] = []) {
        self.entries = entries
    }

    public func record(_ entry: AuditEntry) {
        entries.append(entry)
    }

    public func readAll() -> [AuditEntry] { entries }

    public func clear() throws {
        if let clearFailure { throw clearFailure }
        clearCount += 1
        entries = []
    }

    public func setClearFailure(_ error: (any Error)?) {
        clearFailure = error
    }

    public nonisolated var location: URL? { nil }

    public func sizeOnDisk() -> Int { entries.count * 200 }

    /// `kind:outcome` for each entry, for compact assertions.
    public var summary: [String] {
        entries.map { entry in
            [entry.kind.rawValue, entry.tool, entry.outcome].compactMap { $0 }.joined(separator: ":")
        }
    }
}

/// Collects agent events from the `@Sendable` callback.
public final class EventCollector: Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [AgentEvent]())

    public init() {}

    public var events: [AgentEvent] { store.withLock { $0 } }

    public var handler: AgentEventHandler {
        { [store] event in store.withLock { $0.append(event) } }
    }
}
