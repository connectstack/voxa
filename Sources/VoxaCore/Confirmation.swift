import Foundation

/// Everything the user needs to decide about one action, shown in the confirmation HUD. Built by the policy engine from the
/// tool's own assessment, so it always reflects what will really run.
public struct ConfirmationPrompt: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var toolName: String
    public var title: String
    public var summary: String
    public var details: [DetailRow]
    public var targetApp: String?
    public var risk: RiskLevel
    /// Why Voxa is asking (the action's risk, or "outside content was read earlier in this command").
    public var reasons: [String]
    /// How long to wait before treating silence as a refusal.
    public var timeout: Duration

    public init(
        id: UUID = UUID(),
        toolName: String,
        title: String,
        summary: String,
        details: [DetailRow] = [],
        targetApp: String? = nil,
        risk: RiskLevel,
        reasons: [String] = [],
        timeout: Duration = .seconds(60)
    ) {
        self.id = id
        self.toolName = toolName
        self.title = title
        self.summary = summary
        self.details = details
        self.targetApp = targetApp
        self.risk = risk
        self.reasons = reasons
        self.timeout = timeout
    }
}

public enum ConfirmationOutcome: Sendable, Equatable {
    case approved
    /// The user said no.
    case denied
    /// The whole command was cancelled (Esc).
    case cancelled
    /// Nobody answered in time. Treated as a refusal.
    case timedOut
}

/// Asks the user. Implemented by the HUD (buttons, keyboard, voice); tests substitute a scripted answer.
public protocol ConfirmationProviding: Sendable {
    func confirm(_ prompt: ConfirmationPrompt) async -> ConfirmationOutcome
}
