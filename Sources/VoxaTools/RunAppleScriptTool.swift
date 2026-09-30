import Foundation
import VoxaCore
import VoxaPolicy

/// Runs an AppleScript, out of process, after the user has read it and said yes.
///
/// This is the most powerful tool Voxa has and the one most worth being careful with, so:
/// - it is **always sensitive**: the user sees the whole script and what it controls before it runs;
/// - `AppleScriptAnalyzer` refuses the routes to a shell (`do shell script`, Terminal, other scripts, Objective-C, remote
///   machines) before anyone is asked;
/// - it runs in a separate `osascript` process with a minimal environment and a time limit, and is killed on cancel.
public struct RunAppleScriptTool: TypedTool {
    public struct Input: ToolInput {
        public let script: String
    }

    public let name = "run_applescript"
    public let summary = """
        Runs an AppleScript and returns its result. Use it only when no dedicated tool (open_app, open_url, calendar, \
        reminders, clipboard) and no Shortcut can do the job. Name each application in quotes, for example: tell \
        application "Finder". Keep scripts short and readable: the user reads the whole script before it runs. Shell \
        commands (do shell script), Terminal, and running other scripts are not allowed.
        """
    public let inputSchema = Schema.object(
        [
            "script": Schema.string(
                "The complete AppleScript source",
                minLength: 1,
                maxLength: AppleScriptAnalyzer.maxCharacters
            )
        ],
        required: ["script"]
    )
    public let baselineRisk = RiskLevel.sensitive
    public let requiredPermissions: Set<PermissionKind> = [.automation]
    public let stepKind = TaskStepKind.acts

    private let runner: any ProcessRunning
    private let timeout: Duration
    private let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    public init(runner: any ProcessRunning, timeout: Duration = .seconds(25)) {
        self.runner = runner
        self.timeout = timeout
    }

    public func assess(_ input: Input) throws -> ToolAssessment {
        let analysis = AppleScriptAnalyzer.analyze(input.script)
        let controls = analysis.targetApps.joined(separator: ", ")

        var details = [DetailRow("Script", input.script, style: .code)]
        if !controls.isEmpty { details.append(DetailRow("Controls", controls)) }

        return ToolAssessment(
            risk: .sensitive,
            title: "Run an AppleScript",
            summary: controls.isEmpty ? "Runs an AppleScript." : "Runs an AppleScript that controls \(controls).",
            details: details,
            targetApp: analysis.targetApps.first,
            reasons: ["AppleScript can control other apps."] + analysis.capabilities + Self.lengthWarning(lines: analysis.lineCount),
            block: analysis.blockReason
        )
    }

    public func run(_ input: Input, context: ToolContext) async throws -> ToolResult {
        // Checked again at the moment of running: what executes is what the analyzer accepted.
        if let reason = AppleScriptAnalyzer.analyze(input.script).blockReason {
            throw ToolInputError(reason)
        }
        let output: ProcessOutput
        do {
            output = try await runner.run(
                executable: osascript,
                arguments: ["-l", "AppleScript", "-"],
                standardInput: Data(input.script.utf8),
                timeout: timeout
            )
        } catch ProcessError.timedOut {
            return .error("The script didn't finish in time and was stopped. It may have partly run.")
        } catch ProcessError.launchFailed(let reason) {
            return .error("AppleScript couldn't be started: \(reason)")
        }

        let stderr = output.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.succeeded else {
            return .error(Self.explain(stderr), provenance: .untrusted(source: "AppleScript error"))
        }
        let stdout = output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = output.wasTruncated ? "\n[output was cut off]" : ""
        if stdout.isEmpty {
            return .text("The script ran and returned nothing.", notice: "Ran the script")
        }
        return .text(stdout + suffix, provenance: .untrusted(source: "AppleScript output"), notice: "Ran the script")
    }

    /// The card shows about ten lines of the script at a time. A long script gets a reminder that the rest is below, since a
    /// script that looks harmless at the top is exactly how a bad one would hide.
    static let visibleLines = 10

    static func lengthWarning(lines: Int) -> [String] {
        lines > visibleLines ? ["The script is \(lines) lines long. Scroll to read all of it before you allow it."] : []
    }

    /// Adds the plain-language meaning of the errors a person can act on. The original text is kept, since it is what
    /// identifies the problem.
    static func explain(_ stderr: String) -> String {
        let text = stderr.isEmpty ? "The script failed." : stderr
        if text.contains("-1743") {
            return text
                + "\nVoxa isn't allowed to control that app yet. "
                + "The user can allow it in System Settings → Privacy & Security → Automation."
        }
        if text.contains("-600") {
            return text + "\nThat app isn't running; open it first."
        }
        return text
    }
}
