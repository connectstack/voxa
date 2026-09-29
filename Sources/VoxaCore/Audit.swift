import Foundation

/// One line of the local audit trail. Deliberately flat and `Codable`, so the on-disk format is plain JSON Lines that the
/// Settings viewer, `grep` and `jq` can all read.
public struct AuditEntry: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The user's spoken command.
        case command
        /// The model asked for a tool.
        case toolProposed
        /// The policy engine's verdict (allow, notice, confirm, deny).
        case policyDecision
        /// The user's answer to a confirmation.
        case confirmation
        /// What the tool returned.
        case toolResult
        /// The final reply shown to the user.
        case reply
        /// The run ended in a failure.
        case failure
    }

    public var id: UUID
    public var timestamp: Date
    public var runID: UUID
    public var kind: Kind
    public var tool: String?
    public var risk: RiskLevel?
    /// A short verdict or outcome word ("allow", "confirm", "approved", "error"...).
    public var outcome: String?
    /// Free text: the command, the reply, or a compact rendering of the tool arguments.
    public var detail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        runID: UUID,
        kind: Kind,
        tool: String? = nil,
        risk: RiskLevel? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.runID = runID
        self.kind = kind
        self.tool = tool
        self.risk = risk
        self.outcome = outcome
        self.detail = detail
    }
}

/// Append-only. Implementations must never throw into the caller: a broken log must not stop the agent, but it must not be
/// silent either (implementations log the failure).
public protocol AuditLogging: Sendable {
    func record(_ entry: AuditEntry) async
}

public struct DiscardingAuditLog: AuditLogging {
    public init() {}
    public func record(_ entry: AuditEntry) async {}
}
