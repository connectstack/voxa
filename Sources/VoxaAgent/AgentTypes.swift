import Foundation
import VoxaCore
import VoxaLLM

/// The ceilings on one command. All are hard limits: hitting one ends the run with a plain-language reply.
public struct AgentLimits: Sendable, Equatable {
    /// How long one tool may run before it is abandoned.
    public var perToolTimeout: Duration
    /// How long the whole command may take, **not counting the time spent waiting for the user to answer a confirmation**.
    public var totalTimeout: Duration
    /// After this many declined actions the run stops instead of nagging.
    public var maxDeclines: Int
    /// A tool result longer than this is cut, so one runaway result can't fill the model's context.
    public var maxToolResultCharacters: Int
    /// How long the check that a command is finished may take. Past this the model's reply is accepted as it stands.
    public var checkTimeout: Duration

    public init(
        perToolTimeout: Duration = .seconds(30),
        totalTimeout: Duration = .seconds(120),
        maxDeclines: Int = 2,
        maxToolResultCharacters: Int = 20_000,
        checkTimeout: Duration = .seconds(15)
    ) {
        self.perToolTimeout = perToolTimeout
        self.totalTimeout = totalTimeout
        self.maxDeclines = maxDeclines
        self.maxToolResultCharacters = maxToolResultCharacters
        self.checkTimeout = checkTimeout
    }
}

/// The settings one run uses, copied at its start so changing a setting mid-command can't change that command's rules.
public struct AgentRunConfiguration: Sendable, Equatable {
    /// Which service answers, and the model, address and context window to ask it for.
    public var provider: ModelProvider
    public var model: String
    public var endpoint: URL?
    public var contextLength: Int?
    public var effort: ReasoningEffort
    public var useRefusalFallback: Bool
    public var maxSteps: Int
    public var strictness: ConfirmationStrictness
    /// The user has given Voxa full control when the command started. Copied here like the rest, so switching it *on* mid-command
    /// changes nothing about that command; switching it *off* does (`AgentLoop.fullControlStillOn`), since that only ever asks more.
    public var fullControl: Bool
    /// Whether the reply is checked against the command before it is accepted.
    public var verifyCompletion: Bool
    public var disabledTools: Set<String>
    public var followUpWindow: TimeInterval

    public init(_ settings: AppSettings) {
        provider = settings.provider
        model = settings.activeModel
        endpoint = settings.activeBaseURL
        contextLength = settings.provider == .ollama ? settings.ollamaContextLength : nil
        effort = settings.effort
        useRefusalFallback = settings.useRefusalFallback
        maxSteps = settings.maxAgentSteps
        strictness = settings.confirmationStrictness
        fullControl = settings.fullControl
        verifyCompletion = settings.verifyCompletion
        disabledTools = settings.disabledTools
        followUpWindow = TimeInterval(settings.followUpWindowSeconds)
    }
}

/// What the loop reports while it works, for the HUD, the menu-bar icon and the audit trail.
public enum AgentEvent: Sendable, Equatable {
    /// Waiting for the model. `step` counts model turns from 1.
    case thinking(step: Int)
    /// What the model has written so far this turn. Each event replaces the previous one.
    case replyText(String)
    /// A tool is about to run.
    case acting(title: String)
    case finishedTool(title: String, succeeded: Bool, notice: String?)
    /// The user is being asked; the loop is paused until they answer.
    case awaitingConfirmation(ConfirmationPrompt)
    /// The request was interrupted and is being retried.
    case retrying
}

public typealias AgentEventHandler = @Sendable (AgentEvent) -> Void

public struct AgentRunResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// The model finished the command.
        case completed
        /// The user pressed Esc.
        case cancelled
        case failed(UserFacingError)
        case limitReached(steps: Int)
        case timedOut
        /// The model declined the request.
        case refused
        /// The user declined actions repeatedly, so Voxa stopped asking.
        case stoppedAfterDeclines
    }

    public var outcome: Outcome
    /// What to show and speak.
    public var reply: String
    /// Model turns used.
    public var steps: Int
    /// The titles of the actions that actually ran, in order.
    public var actions: [String]
    public var usage: Usage

    public init(outcome: Outcome, reply: String, steps: Int = 0, actions: [String] = [], usage: Usage = Usage()) {
        self.outcome = outcome
        self.reply = reply
        self.steps = steps
        self.actions = actions
        self.usage = usage
    }
}
