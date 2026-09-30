import Foundation

/// How much harm an action can do and how easily it can be undone. The tier decides how the app gates it.
public enum RiskLevel: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Reads or reports; changes nothing. Runs without asking.
    case readOnly = 0
    /// Changes state in a way the user can see and undo (opening an app or a page). Runs, and the HUD says what happened.
    case reversible = 1
    /// Sends, deletes, moves, buys, posts, or changes system settings, or runs code whose effect can't be predicted.
    /// Needs the user's explicit confirmation, whatever the model says. The one thing that lifts that is the user's own
    /// choice to give Voxa full control (`AppSettings.fullControl`).
    case sensitive = 2

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How eagerly the app asks before acting. Sensitive actions always ask; this only raises the bar for the rest. (Full control,
/// a separate switch, is the only thing that lowers it.)
public enum ConfirmationStrictness: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Ask for sensitive actions, and for anything that follows outside content entering the command.
    case standard
    /// Also ask before every state-changing action.
    case strict
    /// Ask before everything, even reads.
    case paranoid

    public var id: String { rawValue }

    /// Orders the levels so the policy can ask "at least strict".
    public var rank: Int {
        switch self {
        case .standard: 0
        case .strict: 1
        case .paranoid: 2
        }
    }
}

/// Where a tool's output came from, which decides whether the model may treat it as instructions (it never may) and
/// whether it raises the bar for what follows.
public enum Provenance: Sendable, Equatable {
    /// Text the app itself produced ("Opened Safari").
    case trusted
    /// Content that originates outside the app: a script's output, a file, a web page, the clipboard, the screen.
    case untrusted(source: String)

    public var isUntrusted: Bool {
        if case .untrusted = self { true } else { false }
    }
}

public enum ToolContent: Sendable, Equatable {
    case text(String)
    case image(Data, mediaType: String)
}

/// What a tool returns to the agent loop.
public struct ToolResult: Sendable, Equatable {
    public var content: [ToolContent]
    public var isError: Bool
    public var provenance: Provenance
    /// One short line for the HUD, such as "Opened Safari".
    public var notice: String?

    public init(content: [ToolContent], isError: Bool = false, provenance: Provenance = .trusted, notice: String? = nil) {
        self.content = content
        self.isError = isError
        self.provenance = provenance
        self.notice = notice
    }

    public static func text(_ text: String, provenance: Provenance = .trusted, notice: String? = nil) -> ToolResult {
        ToolResult(content: [.text(text)], provenance: provenance, notice: notice)
    }

    public static func error(_ message: String, provenance: Provenance = .trusted) -> ToolResult {
        ToolResult(content: [.text(message)], isError: true, provenance: provenance)
    }

    /// The text parts joined together (images are skipped).
    public var plainText: String {
        content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    /// Whether any content reaches the model at all (an empty result carries no outside data).
    public var hasContent: Bool {
        content.contains {
            switch $0 {
            case .text(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image: true
            }
        }
    }
}

/// One labelled line in a confirmation prompt.
public struct DetailRow: Sendable, Equatable, Hashable {
    public enum Style: Sendable, Equatable, Hashable {
        case plain
        /// Monospaced: scripts, identifiers.
        case code
        case url
    }

    public var label: String
    public var value: String
    public var style: Style

    public init(_ label: String, _ value: String, style: Style = .plain) {
        self.label = label
        self.value = value
        self.style = style
    }
}

/// A tool's own description of a validated call: how risky it is and what exactly it will do. Written by the tool's code
/// from the decoded arguments, never by the model, so a confirmation can't be talked into hiding anything.
public struct ToolAssessment: Sendable, Equatable {
    public var risk: RiskLevel
    public var title: String
    public var summary: String
    public var details: [DetailRow]
    public var targetApp: String?
    /// Why the call has this risk, in plain words ("Runs a script that can control other apps").
    public var reasons: [String]
    /// Non-nil means the call must never run; the string explains why to the user and the model.
    public var block: String?

    public init(
        risk: RiskLevel,
        title: String,
        summary: String,
        details: [DetailRow] = [],
        targetApp: String? = nil,
        reasons: [String] = [],
        block: String? = nil
    ) {
        self.risk = risk
        self.title = title
        self.summary = summary
        self.details = details
        self.targetApp = targetApp
        self.reasons = reasons
        self.block = block
    }
}

public struct ToolContext: Sendable {
    public var runID: UUID
    public var locale: Locale

    public init(runID: UUID = UUID(), locale: Locale = .current) {
        self.runID = runID
        self.locale = locale
    }
}

/// The name, description and input schema the model sees for a tool.
public struct ToolDefinition: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Thrown when the model's arguments don't match the tool's schema. The message goes back to the model as an error result.
public struct ToolInputError: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// What a tool call amounts to in a longer job. Opening a page is not playing what is on it, and one click is not the whole of
/// "fill in the form", so a command that used these may be unfinished when the model wants to reply.
public enum TaskStepKind: Sendable, Equatable {
    /// Does the whole of what it says (add an event, copy text, move a file), or only passes time (wait).
    case other
    /// Opens something (a page, an app): the start of "play it" or "fill it in", never its end.
    case opens
    /// Does something in what was opened: a click, keys, typing, a script.
    case acts
    /// Only looks (a listing of the window, a picture): changes nothing, but shows how things stand.
    case looks
}

/// A capability the agent can use. Conformers are small and stateless; anything that touches the system goes through an
/// injected protocol so the tool logic is testable without the system.
public protocol AgentTool: Sendable {
    var name: String { get }
    /// What the model reads. Say *when* to use the tool, not just what it does.
    var summary: String { get }
    var inputSchema: JSONValue { get }
    /// The lowest risk this tool can ever have. `assess` may only raise it.
    var baselineRisk: RiskLevel { get }
    var requiredPermissions: Set<PermissionKind> { get }
    /// What a call of this tool amounts to in a longer job (`TaskStepKind`). The loop uses it to decide whether a command needs
    /// a check that it is really finished before its reply is accepted.
    var stepKind: TaskStepKind { get }

    /// Validates `input` and describes what the call would do. Throws `ToolInputError` for arguments that don't match.
    func assess(_ input: JSONValue) throws -> ToolAssessment
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult
}

extension AgentTool {
    /// Most tools do the whole of what they say (add an event, copy text, move a file), or only pass time.
    public var stepKind: TaskStepKind { .other }

    public var definition: ToolDefinition {
        ToolDefinition(name: name, description: summary, inputSchema: inputSchema)
    }
}

/// A tool whose arguments are a `Decodable` type. Decoding and error reporting are shared, so a tool only writes its
/// logic against its typed input.
public protocol ToolInput: Decodable, Sendable {}

public protocol TypedTool: AgentTool {
    associatedtype Input: ToolInput

    func assess(_ input: Input) throws -> ToolAssessment
    func run(_ input: Input, context: ToolContext) async throws -> ToolResult
}

extension TypedTool {
    public func assess(_ input: JSONValue) throws -> ToolAssessment {
        try assess(Self.decode(input))
    }

    public func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult {
        try await run(Self.decode(input), context: context)
    }

    static func decode(_ input: JSONValue) throws -> Input {
        do {
            let data = try JSONEncoder().encode(input)
            return try JSONDecoder().decode(Input.self, from: data)
        } catch let error as DecodingError {
            throw ToolInputError(Self.describe(error))
        } catch {
            throw ToolInputError("The arguments could not be read: \(error.localizedDescription)")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, _):
            return "Missing required argument '\(key.stringValue)'."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "Argument '\(path(context))' has the wrong type."
        case .dataCorrupted(let context):
            return "Argument '\(path(context))' is invalid."
        @unknown default:
            return "The arguments don't match the tool's schema."
        }
    }
}
