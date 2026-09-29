import Foundation
import VoxaCore
import VoxaLLM
import VoxaPolicy

/// The agent as the app uses it: one long-lived object that owns the conversation, reads the current settings for every
/// command, and runs the loop. There is at most one command at a time.
public actor AgentService {
    private let llm: any LLMClient
    private let registry: ToolRegistry
    private let confirmations: any ConfirmationProviding
    private let permissions: any ToolPermissionGranting
    private let audit: any AuditLogging
    private let systemPrompt: SystemPrompt
    private let clock: any Clock<Duration>
    private let limits: AgentLimits
    private let settings: @Sendable () async -> AppSettings

    private var memory = ConversationMemory()
    private var isRunning = false

    /// - Parameter settings: Called at the start of every command, so a change in Settings applies to the next command.
    public init(
        llm: any LLMClient,
        registry: ToolRegistry,
        confirmations: any ConfirmationProviding,
        permissions: any ToolPermissionGranting = UnrestrictedToolPermissions(),
        audit: any AuditLogging = DiscardingAuditLog(),
        systemPrompt: SystemPrompt,
        clock: any Clock<Duration> = ContinuousClock(),
        limits: AgentLimits = AgentLimits(),
        settings: @escaping @Sendable () async -> AppSettings
    ) {
        self.llm = llm
        self.registry = registry
        self.confirmations = confirmations
        self.permissions = permissions
        self.audit = audit
        self.systemPrompt = systemPrompt
        self.clock = clock
        self.limits = limits
        self.settings = settings
    }

    /// Whether a follow-up command would still see an earlier one.
    public var hasConversation: Bool { !memory.isEmpty }

    /// Forgets the conversation, including what it read from outside. Called when the user starts over.
    public func resetConversation() {
        memory.reset()
    }

    /// Runs one command to completion. Cancel the calling task to stop it.
    public func run(_ command: String, now: Date = Date(), onEvent: AgentEventHandler? = nil) async -> AgentRunResult {
        guard !isRunning else {
            return AgentRunResult(
                outcome: .failed(UserFacingError(title: L10n.Agent.busy, detail: "")),
                reply: L10n.Agent.busy
            )
        }
        isRunning = true
        defer { isRunning = false }

        let snapshot = await settings()
        let configuration = AgentRunConfiguration(snapshot)

        if !registry.names.isEmpty, registry.definitions(excluding: configuration.disabledTools).isEmpty {
            return AgentRunResult(outcome: .completed, reply: L10n.Agent.noTools)
        }

        if let reason = memory.prepare(
            now: now,
            window: configuration.followUpWindow,
            fingerprint: fingerprint(for: configuration)
        ) {
            Log.agent.info("conversation reset: \(String(describing: reason), privacy: .public)")
        }

        let loop = AgentLoop(
            llm: llm,
            registry: registry,
            confirmations: confirmations,
            permissions: permissions,
            audit: audit,
            systemPrompt: systemPrompt,
            clock: clock,
            limits: limits(for: configuration.provider)
        )
        let output = await loop.run(
            command: command,
            memory: memory,
            configuration: configuration,
            context: RuntimeContext(now: now),
            onEvent: onEvent
        )
        memory = output.memory
        return output.result
    }

    /// A model on this Mac may need to load before it answers and then generates slowly, so a command gets longer to finish
    /// than one sent over the network. The other limits, and the user's own time to decide, are unchanged.
    func limits(for provider: ModelProvider) -> AgentLimits {
        guard provider == .ollama else { return limits }
        var adjusted = limits
        adjusted.totalTimeout = max(limits.totalTimeout, Self.localModelTimeout)
        return adjusted
    }

    static let localModelTimeout: Duration = .seconds(300)

    /// Everything that shapes a request. History built under one fingerprint can't be reused under another.
    private func fingerprint(for configuration: AgentRunConfiguration) -> String {
        [
            configuration.provider.rawValue,
            configuration.endpoint?.absoluteString ?? "",
            configuration.contextLength.map(String.init) ?? "",
            configuration.model,
            configuration.effort.rawValue,
            String(configuration.useRefusalFallback),
            String(configuration.maxSteps),
            String(systemPrompt.render(maxSteps: configuration.maxSteps).hashValue),
            registry.definitions(excluding: configuration.disabledTools).map(\.name).joined(separator: ","),
        ].joined(separator: "|")
    }
}
