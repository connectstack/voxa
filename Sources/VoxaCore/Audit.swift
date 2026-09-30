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
        /// A tool needed a system permission Voxa didn't have yet: it asked, or the user had said no.
        case permission
        /// Whether the model's answer was checked against what the user asked before it was accepted.
        case completionCheck
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

/// Reading the audit trail back, for the history view in Settings. Separate from `AuditLogging` on purpose: the agent only
/// ever *writes*, so nothing in the loop can read (or leak) the record of what was done.
public protocol AuditReading: Sendable {
    /// Every entry, oldest first.
    func readAll() async -> [AuditEntry]
    /// Deletes the whole trail. The only way entries are ever removed, and only when the user asks.
    func clear() async throws
    /// The file the trail lives in, for "Show in Finder"; nil when it isn't kept in a file.
    var location: URL? { get }
    /// How much room the trail takes on disk.
    func sizeOnDisk() async -> Int
}

/// One command and everything that happened while it ran, in order.
public struct AuditRun: Identifiable, Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case completed
        case cancelled
        case failed
        /// It ran out of steps or time.
        case stopped
        /// The model declined the request.
        case refused
        /// The user said no to what it wanted to do.
        case declined
        /// The trail ends without a result: the app quit, or crashed, mid-command.
        case unfinished
    }

    public var id: UUID
    public var start: Date
    /// What the user said. Empty if the trail has no record of it (an older run whose first lines were rotated away).
    public var command: String
    /// The reply shown to the user, or the failure's title.
    public var reply: String?
    public var outcome: Outcome
    public var entries: [AuditEntry]

    /// The tools the model asked for, once each, in the order first asked.
    public var tools: [String] {
        var seen: [String] = []
        for entry in entries where entry.kind == .toolProposed {
            if let tool = entry.tool, !seen.contains(tool) { seen.append(tool) }
        }
        return seen
    }

    /// How many times the user was asked.
    public var questionsAsked: Int { entries.filter { $0.kind == .confirmation }.count }
}

public enum AuditGrouping {
    /// Groups a trail into commands, newest first. A run's entries stay in the order they were written.
    public static func runs(from entries: [AuditEntry]) -> [AuditRun] {
        var order: [UUID] = []
        var byRun: [UUID: [AuditEntry]] = [:]
        for entry in entries {
            if byRun[entry.runID] == nil { order.append(entry.runID) }
            byRun[entry.runID, default: []].append(entry)
        }
        let runs = order.compactMap { id -> AuditRun? in
            guard let entries = byRun[id], let first = entries.first else { return nil }
            let command = entries.first { $0.kind == .command }?.detail ?? ""
            let last = entries.last { $0.kind == .reply || $0.kind == .failure }
            return AuditRun(
                id: id,
                start: first.timestamp,
                command: command,
                reply: last?.detail.flatMap { $0.isEmpty ? nil : $0 },
                outcome: outcome(of: last, in: entries),
                entries: entries
            )
        }
        return runs.sorted { $0.start > $1.start }
    }

    private static func outcome(of last: AuditEntry?, in entries: [AuditEntry]) -> AuditRun.Outcome {
        guard let last else { return .unfinished }
        switch last.outcome {
        case "completed": return .completed
        case "cancelled": return .cancelled
        case "failed": return .failed
        case "limit", "timeout": return .stopped
        case "refused": return .refused
        case "declined": return .declined
        default: return last.kind == .failure ? .failed : .completed
        }
    }
}
