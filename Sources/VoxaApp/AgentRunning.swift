import Foundation
import VoxaAgent

/// What the session controller needs from the agent: run one command. `AgentService` is the real implementation; tests
/// substitute one they can script and hold open.
public protocol AgentRunning: Sendable {
    func run(_ command: String, now: Date, onEvent: AgentEventHandler?) async -> AgentRunResult
}

extension AgentService: AgentRunning {}
