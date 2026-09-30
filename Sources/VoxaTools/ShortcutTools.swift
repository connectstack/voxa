import Foundation
import VoxaCore

private let shortcutsExecutable = URL(fileURLWithPath: "/usr/bin/shortcuts")

/// Lists the user's Shortcuts by name, so the model can pick one that exists.
public struct ListShortcutsTool: TypedTool {
    public struct Input: ToolInput {}

    public let name = "list_shortcuts"
    public let summary =
        "Lists the names of the user's Shortcuts (from the Shortcuts app). Use it before run_shortcut when you don't know the exact name."
    public let inputSchema = Schema.object([:])
    public let baselineRisk = RiskLevel.readOnly
    public let requiredPermissions: Set<PermissionKind> = []

    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning) {
        self.runner = runner
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        ToolAssessment(risk: .readOnly, title: "List your Shortcuts", summary: "Reads the names of your Shortcuts.")
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let output: ProcessOutput
        do {
            output = try await runner.run(
                executable: shortcutsExecutable,
                arguments: ["list"],
                standardInput: nil,
                timeout: .seconds(15)
            )
        } catch ProcessError.timedOut {
            return .error("Listing Shortcuts took too long.")
        } catch ProcessError.launchFailed(let reason) {
            return .error("The Shortcuts command couldn't be started: \(reason)")
        }
        guard output.succeeded else {
            return .error("Shortcuts couldn't be listed.", provenance: .untrusted(source: "Shortcuts"))
        }
        let names = output.standardOutput.split(separator: "\n").map(String.init).prefix(200)
        if names.isEmpty { return .text("The user has no Shortcuts.") }
        // Names are chosen by whoever made or shared the shortcut, so they are data.
        return .text(names.joined(separator: "\n"), provenance: .untrusted(source: "Shortcuts list"))
    }
}

/// Runs a Shortcut by name.
public struct RunShortcutTool: TypedTool {
    public struct Input: ToolInput {
        public let name: String
        public let input: String?
    }

    public let name = "run_shortcut"
    public let summary = """
        Runs one of the user's Shortcuts by its exact name, optionally giving it some text as input, and returns its text \
        output. Prefer a dedicated tool when one exists; use this when the user names a Shortcut or asks for something a \
        Shortcut of theirs does. Use list_shortcuts to find the name.
        """
    public let inputSchema = Schema.object(
        [
            "name": Schema.string("The Shortcut's exact name", minLength: 1, maxLength: 200),
            "input": Schema.string("Optional text to pass to the Shortcut as input", maxLength: 10_000),
        ],
        required: ["name"]
    )
    /// A Shortcut can do anything, and Voxa can't see inside one.
    public let baselineRisk = RiskLevel.sensitive
    public let requiredPermissions: Set<PermissionKind> = []
    public let stepKind = TaskStepKind.acts

    private let runner: any ProcessRunning
    private let timeout: Duration

    public init(runner: any ProcessRunning, timeout: Duration = .seconds(25)) {
        self.runner = runner
        self.timeout = timeout
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        // A name that starts with a dash would be read by the command as an option, not as a name.
        let startsLikeOption = input.name.hasPrefix("-")
        let hasControlCharacters = input.name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        if startsLikeOption || hasControlCharacters {
            throw ToolInputError("That isn't a valid Shortcut name. Use list_shortcuts to find the exact name.")
        }
        var details = [DetailRow("Shortcut", input.name)]
        if let text = input.input, !text.isEmpty { details.append(DetailRow("Input", text, style: .code)) }
        return ToolAssessment(
            risk: .sensitive,
            title: "Run the Shortcut “\(input.name)”",
            summary: "Runs your Shortcut “\(input.name)”.",
            details: details,
            targetApp: "Shortcuts",
            reasons: [
                "A Shortcut can open apps, send messages and change files, and Voxa can't see what this one does."
            ]
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxa-shortcut-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The folder made just above, for the Shortcut's input and output: Voxa's own temporary files, not the person's.
        // swiftlint:disable:next no_file_deletion_in_tools
        defer { try? FileManager.default.removeItem(at: scratch) }

        var arguments = ["run", input.name]
        if let text = input.input, !text.isEmpty {
            let inputFile = scratch.appendingPathComponent("input.txt")
            try Data(text.utf8).write(to: inputFile, options: .atomic)
            arguments += ["--input-path", inputFile.path]
        }
        let outputFile = scratch.appendingPathComponent("output.txt")
        arguments += ["--output-path", outputFile.path, "--output-type", "public.plain-text"]

        let result: ProcessOutput
        do {
            result = try await runner.run(
                executable: shortcutsExecutable,
                arguments: arguments,
                standardInput: nil,
                timeout: timeout
            )
        } catch ProcessError.timedOut {
            return .error("The Shortcut didn't finish in time and was stopped. It may have partly run.")
        } catch ProcessError.launchFailed(let reason) {
            return .error("The Shortcuts command couldn't be started: \(reason)")
        }

        guard result.succeeded else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            return .error(
                message.isEmpty ? "The Shortcut failed." : message,
                provenance: .untrusted(source: "Shortcuts error")
            )
        }
        let produced = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        if produced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text("The Shortcut ran and produced no output.", notice: "Ran “\(input.name)”")
        }
        return .text(produced, provenance: .untrusted(source: "Shortcut output"), notice: "Ran “\(input.name)”")
    }
}
