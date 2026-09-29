import Foundation
import Testing
import VoxaCore
import VoxaPolicy
import VoxaTestSupport
@testable import VoxaTools

@Suite("run_applescript")
struct RunAppleScriptToolTests {
    private func tool(
        _ runner: FakeProcessRunner = FakeProcessRunner(returning: ProcessOutput(status: 0))
    ) -> RunAppleScriptTool {
        RunAppleScriptTool(runner: runner)
    }

    // MARK: Assessment

    @Test("it is always sensitive, and shows the whole script and what it controls")
    func assessment() throws {
        let script = "tell application \"Finder\"\n  get name of startup disk\nend tell"
        let assessment = try tool().assess(["script": .string(script)])
        #expect(assessment.risk == .sensitive)
        #expect(assessment.title == "Run an AppleScript")
        #expect(assessment.summary == "Runs an AppleScript that controls Finder.")
        #expect(assessment.targetApp == "Finder")
        #expect(assessment.details == [DetailRow("Script", script, style: .code), DetailRow("Controls", "Finder")])
        #expect(assessment.block == nil)
        #expect(assessment.reasons.first == "AppleScript can control other apps.")
    }

    @Test("what the script can do is listed as reasons for the prompt")
    func capabilities() throws {
        let assessment = try tool().assess(["script": #"tell application "System Events" to keystroke "hello""#])
        #expect(assessment.reasons.contains("Types keystrokes or presses keys in whichever app is in front"))
    }

    @Test("a script longer than the card's window carries a reminder to scroll; a short one doesn't")
    func longScriptWarning() throws {
        let long = (1...25).map { "display dialog \"line \($0)\"" }.joined(separator: "\n")
        let longAssessment = try tool().assess(["script": .string(long)])
        #expect(longAssessment.reasons.contains("The script is 25 lines long. Scroll to read all of it before you allow it."))

        let short = try tool().assess(["script": "display dialog \"hi\""])
        #expect(!short.reasons.contains { $0.contains("Scroll") })
        #expect(RunAppleScriptTool.lengthWarning(lines: RunAppleScriptTool.visibleLines).isEmpty)
        #expect(!RunAppleScriptTool.lengthWarning(lines: RunAppleScriptTool.visibleLines + 1).isEmpty)
    }

    @Test(
        "scripts that reach a shell or another script are blocked with the reason",
        arguments: [
            #"do shell script "rm -rf ~""#, #"tell application "Terminal" to do script "ls""#,
            #"run script "return 1""#,
            "use framework \"Foundation\"", #"tell application ("Ter" & "minal") to activate"#,
        ]
    )
    func blocked(script: String) throws {
        let assessment = try tool().assess(["script": .string(script)])
        #expect(assessment.block != nil)
        #expect(assessment.risk == .sensitive)
    }

    @Test("the policy asks about a normal script and refuses a blocked one, whatever the strictness")
    func withPolicy() throws {
        let scriptTool = tool()
        let fine = try scriptTool.assess(["script": #"tell application "Finder" to activate"#])
        let bad = try scriptTool.assess(["script": #"do shell script "ls""#])
        for strictness in ConfirmationStrictness.allCases {
            let engine = PolicyEngine(configuration: PolicyConfiguration(strictness: strictness))
            #expect(
                engine.evaluate(toolName: scriptTool.name, baselineRisk: scriptTool.baselineRisk, assessment: fine, taint: RunTaint())
                    .isConfirmation
            )
            #expect(
                engine.evaluate(toolName: scriptTool.name, baselineRisk: scriptTool.baselineRisk, assessment: bad, taint: RunTaint())
                    .isDenial
            )
        }
    }

    @Test("a tool that misreports its own risk still asks, through the policy's floor")
    func floor() throws {
        let fine = try tool().assess(["script": "return 1"])
        let lowered = ToolAssessment(risk: .readOnly, title: fine.title, summary: fine.summary)
        let decision = PolicyEngine().evaluate(
            toolName: "run_applescript",
            baselineRisk: .readOnly,
            assessment: lowered,
            taint: RunTaint()
        )
        #expect(decision.isConfirmation)
    }

    // MARK: Execution

    @Test("the script goes to osascript on standard input, never on the command line")
    func invocation() async throws {
        let runner = FakeProcessRunner(returning: ProcessOutput(status: 0, standardOutput: "42\n"))
        let result = try await tool(runner).execute(["script": "return 6 * 7"], context: ToolContext())

        let call = try #require(runner.recorded.first)
        #expect(call.executable == "/usr/bin/osascript")
        #expect(call.arguments == ["-l", "AppleScript", "-"])
        #expect(call.standardInput == "return 6 * 7")
        #expect(result.plainText == "42")
        #expect(result.provenance == .untrusted(source: "AppleScript output"))
        #expect(result.notice == "Ran the script")
    }

    @Test("a script that returns nothing says so, as Voxa's own words")
    func emptyOutput() async throws {
        let result = try await tool().execute(["script": "activate"], context: ToolContext())
        #expect(result.plainText == "The script ran and returned nothing.")
        #expect(result.provenance == .trusted)
    }

    @Test("a failure is an error, and its text is treated as data")
    func failure() async throws {
        let runner = FakeProcessRunner(
            returning: ProcessOutput(
                status: 1,
                standardError: "33:36: execution error: The variable foo is not defined. (-2753)\n"
            )
        )
        let result = try await tool(runner).execute(["script": "return foo"], context: ToolContext())
        #expect(result.isError)
        #expect(result.plainText.contains("-2753"))
        #expect(result.provenance == .untrusted(source: "AppleScript error"))
    }

    @Test("the two errors a person can fix come with what to do")
    func explained() async throws {
        let denied = FakeProcessRunner(
            returning: ProcessOutput(status: 1, standardError: "Not authorized to send Apple events to Finder. (-1743)")
        )
        let result = try await tool(denied).execute(["script": "return 1"], context: ToolContext())
        #expect(result.plainText.contains("System Settings → Privacy & Security → Automation"))

        let notRunning = FakeProcessRunner(
            returning: ProcessOutput(status: 1, standardError: "Application isn't running. (-600)")
        )
        #expect(
            try await tool(notRunning).execute(["script": "return 1"], context: ToolContext()).plainText.contains(
                "open it first"
            )
        )
    }

    @Test("a timeout is reported as such")
    func timeout() async throws {
        let runner = FakeProcessRunner { _ in throw ProcessError.timedOut }
        let result = try await tool(runner).execute(["script": "delay 100"], context: ToolContext())
        #expect(result.isError && result.plainText.contains("didn't finish in time"))
    }

    @Test("a blocked script never reaches the runner, even if the policy were bypassed")
    func blockedAtRunTime() async {
        let runner = FakeProcessRunner(returning: ProcessOutput(status: 0))
        await #expect(throws: ToolInputError.self) {
            try await tool(runner).execute(["script": #"do shell script "ls""#], context: ToolContext())
        }
        #expect(runner.recorded.isEmpty)
    }

    @Test("a real osascript runs a harmless script end to end")
    func realOsascript() async throws {
        let result = try await RunAppleScriptTool(runner: SystemProcessRunner()).execute(
            ["script": "return 6 * 7"],
            context: ToolContext()
        )
        #expect(result.plainText == "42", "\(result)")
        #expect(!result.isError)
    }
}

@Suite("Shortcuts tools")
struct ShortcutToolsTests {
    @Test("list_shortcuts returns the names as untrusted data")
    func list() async throws {
        let runner = FakeProcessRunner(
            returning: ProcessOutput(status: 0, standardOutput: "Morning routine\nResize image\n")
        )
        let result = try await ListShortcutsTool(runner: runner).execute([:], context: ToolContext())
        #expect(result.plainText == "Morning routine\nResize image")
        #expect(result.provenance == .untrusted(source: "Shortcuts list"))
        #expect(runner.recorded.first?.arguments == ["list"])
    }

    @Test("with no Shortcuts it says so plainly")
    func listEmpty() async throws {
        let result = try await ListShortcutsTool(runner: FakeProcessRunner(returning: ProcessOutput(status: 0)))
            .execute([:], context: ToolContext())
        #expect(result.plainText == "The user has no Shortcuts.")
        #expect(result.provenance == .trusted)
    }

    @Test("listing is read-only and takes no arguments")
    func listIsReadOnly() throws {
        let tool = ListShortcutsTool(runner: FakeProcessRunner(returning: ProcessOutput(status: 0)))
        #expect(try tool.assess([:]).risk == .readOnly)
        #expect(InputValidator.validate(["x": 1], against: tool.inputSchema).count == 1)
    }

    @Test("running a Shortcut is sensitive and shows its name and input")
    func runAssessment() throws {
        let tool = RunShortcutTool(runner: FakeProcessRunner(returning: ProcessOutput(status: 0)))
        let assessment = try tool.assess(["name": "Resize image", "input": "photo.png"])
        #expect(assessment.risk == .sensitive)
        #expect(assessment.title == "Run the Shortcut “Resize image”")
        #expect(
            assessment.details == [
                DetailRow("Shortcut", "Resize image"), DetailRow("Input", "photo.png", style: .code),
            ]
        )
        #expect(assessment.targetApp == "Shortcuts")
        #expect(!assessment.reasons.isEmpty)
    }

    @Test(
        "a name that would be read as a command-line option is refused",
        arguments: ["-h", "--help", "--output-path", "-i x", "line\nbreak"]
    )
    func optionInjection(name: String) {
        let tool = RunShortcutTool(runner: FakeProcessRunner(returning: ProcessOutput(status: 0)))
        #expect(throws: ToolInputError.self) { try tool.assess(["name": .string(name)]) }
    }

    @Test("running passes the name, an input file and an output file, and returns what the Shortcut produced")
    func run() async throws {
        let seenInput = SeenBox()
        let runner = FakeProcessRunner { call in
            // The scratch files exist only during the call, so inspect them here.
            if let index = call.arguments.firstIndex(of: "--input-path") {
                seenInput.set(try String(contentsOfFile: call.arguments[index + 1], encoding: .utf8))
            }
            let outputPath = call.arguments[call.arguments.firstIndex(of: "--output-path")! + 1]
            try "Resized 1 image".write(toFile: outputPath, atomically: true, encoding: .utf8)
            return ProcessOutput(status: 0)
        }
        let result = try await RunShortcutTool(runner: runner).execute(
            ["name": "Resize image", "input": "photo.png"],
            context: ToolContext()
        )

        let call = try #require(runner.recorded.first)
        #expect(call.executable == "/usr/bin/shortcuts")
        #expect(Array(call.arguments.prefix(2)) == ["run", "Resize image"])
        #expect(seenInput.value == "photo.png")
        #expect(result.plainText == "Resized 1 image")
        #expect(result.provenance == .untrusted(source: "Shortcut output"))
        #expect(result.notice == "Ran “Resize image”")
        // The scratch directory is gone afterwards.
        let outputPath = call.arguments[call.arguments.firstIndex(of: "--output-path")! + 1]
        #expect(!FileManager.default.fileExists(atPath: outputPath))
    }

    @Test("a Shortcut with no output says so; a failing one is an error; a slow one is stopped")
    func outcomes() async throws {
        let quiet = try await RunShortcutTool(runner: FakeProcessRunner(returning: ProcessOutput(status: 0))).execute(
            ["name": "X"],
            context: ToolContext()
        )
        #expect(quiet.plainText == "The Shortcut ran and produced no output.")

        let failing = FakeProcessRunner(
            returning: ProcessOutput(status: 1, standardError: "Error: Couldn't find shortcut 'X'")
        )
        let failed = try await RunShortcutTool(runner: failing).execute(["name": "X"], context: ToolContext())
        #expect(failed.isError && failed.plainText.contains("Couldn't find"))
        #expect(failed.provenance == .untrusted(source: "Shortcuts error"))

        let slow = FakeProcessRunner { _ in throw ProcessError.timedOut }
        let stopped = try await RunShortcutTool(runner: slow).execute(["name": "X"], context: ToolContext())
        #expect(stopped.isError && stopped.plainText.contains("didn't finish in time"))
    }
}

final class SeenBox: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var stored: String?
    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ text: String) {
        lock.lock()
        stored = text
        lock.unlock()
    }
}

@Suite("SystemProcessRunner")
struct SystemProcessRunnerTests {
    private let runner = SystemProcessRunner(maxOutputBytes: 10_000)

    private func exec(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("it captures output and exit status")
    func output() async throws {
        let result = try await runner.run(
            executable: exec("/bin/echo"),
            arguments: ["hello", "world"],
            standardInput: nil,
            timeout: .seconds(5)
        )
        #expect(result.status == 0)
        #expect(result.standardOutput == "hello world\n")
        #expect(result.standardError.isEmpty)
        #expect(result.succeeded)
    }

    @Test("it feeds standard input")
    func input() async throws {
        let result = try await runner.run(
            executable: exec("/bin/cat"),
            arguments: [],
            standardInput: Data("from stdin".utf8),
            timeout: .seconds(5)
        )
        #expect(result.standardOutput == "from stdin")
    }

    @Test("a failing command reports its status and standard error")
    func failure() async throws {
        let result = try await runner.run(
            executable: exec("/bin/ls"),
            arguments: ["/definitely/not/here"],
            standardInput: nil,
            timeout: .seconds(5)
        )
        #expect(result.status != 0)
        #expect(result.standardError.contains("No such file"))
        #expect(!result.succeeded)
    }

    @Test("a program that doesn't exist is a launch failure")
    func launchFailure() async {
        await #expect(throws: ProcessError.self) {
            try await runner.run(
                executable: exec("/no/such/program"),
                arguments: [],
                standardInput: nil,
                timeout: .seconds(5)
            )
        }
    }

    @Test("the child sees a minimal environment, not Voxa's")
    func environment() async throws {
        setenv("VOXA_SECRET_FOR_TEST", "hunter2", 1)
        defer { unsetenv("VOXA_SECRET_FOR_TEST") }
        let result = try await runner.run(
            executable: exec("/usr/bin/env"),
            arguments: [],
            standardInput: nil,
            timeout: .seconds(5)
        )
        #expect(!result.standardOutput.contains("hunter2"))
        #expect(!result.standardOutput.contains("VOXA_SECRET_FOR_TEST"))
        #expect(result.standardOutput.contains("PATH=/usr/bin"))
    }

    @Test("a process that outlives its time limit is stopped")
    func timeout() async throws {
        let started = ContinuousClock.now
        await #expect(throws: ProcessError.timedOut) {
            try await runner.run(
                executable: exec("/bin/sleep"),
                arguments: ["30"],
                standardInput: nil,
                timeout: .milliseconds(300)
            )
        }
        #expect(ContinuousClock.now - started < .seconds(5), "it was killed, not waited for")
    }

    @Test("cancelling the caller stops the process")
    func cancellation() async throws {
        let started = ContinuousClock.now
        let task = Task {
            try await runner.run(
                executable: exec("/bin/sleep"),
                arguments: ["30"],
                standardInput: nil,
                timeout: .seconds(60)
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.result
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("endless output is cut at the limit and the process is stopped")
    func outputLimit() async throws {
        let started = ContinuousClock.now
        let result = try await runner.run(
            executable: exec("/usr/bin/yes"),
            arguments: [],
            standardInput: nil,
            timeout: .seconds(20)
        )
        #expect(result.wasTruncated)
        #expect(result.standardOutput.utf8.count <= 10_000)
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

@Suite("SystemProcessRunner and closed pipes")
struct ClosedPipeTests {
    @Test("a program that exits without reading its input can't take the app down with SIGPIPE")
    func childIgnoresInput() async throws {
        let runner = SystemProcessRunner()
        let big = Data(repeating: 0x41, count: 4 * 1_024 * 1_024)
        for _ in 0..<5 {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], standardInput: big, timeout: .seconds(10)
            )
            #expect(result.status == 0)
        }
    }
}
