import Foundation
import Testing
@testable import VoxaCore

@Suite("AuditGrouping") struct AuditGroupingTests {
    private func entry(
        _ run: UUID,
        _ kind: AuditEntry.Kind,
        at seconds: Double,
        tool: String? = nil,
        outcome: String? = nil,
        detail: String? = nil
    ) -> AuditEntry {
        AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + seconds),
            runID: run,
            kind: kind,
            tool: tool,
            outcome: outcome,
            detail: detail
        )
    }

    private let first = UUID()
    private let second = UUID()

    private func twoRuns() -> [AuditEntry] {
        [
            entry(first, .command, at: 0, detail: "open safari"),
            entry(first, .toolProposed, at: 1, tool: "open_app", detail: #"{"name":"Safari"}"#),
            entry(first, .policyDecision, at: 1, tool: "open_app", outcome: "notice"),
            entry(first, .toolResult, at: 2, tool: "open_app", outcome: "ok"),
            entry(first, .reply, at: 3, outcome: "completed", detail: "Opened Safari."),
            entry(second, .command, at: 60, detail: "run a script"),
            entry(second, .toolProposed, at: 61, tool: "run_applescript"),
            entry(second, .confirmation, at: 62, tool: "run_applescript", outcome: "denied"),
            entry(second, .reply, at: 63, outcome: "declined", detail: "Okay, I didn't do that."),
        ]
    }

    @Test("entries are grouped by the command they belong to, newest command first, each in the order written")
    func grouping() {
        let runs = AuditGrouping.runs(from: twoRuns())
        #expect(runs.map(\.id) == [second, first])
        #expect(runs[1].entries.map(\.kind) == [.command, .toolProposed, .policyDecision, .toolResult, .reply])
        #expect(runs[1].command == "open safari")
        #expect(runs[1].reply == "Opened Safari.")
        #expect(runs[1].start == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("the outcome, the tools used and the questions asked are worked out for each run")
    func summaries() {
        let runs = AuditGrouping.runs(from: twoRuns())
        #expect(runs[1].outcome == .completed && runs[1].tools == ["open_app"] && runs[1].questionsAsked == 0)
        #expect(runs[0].outcome == .declined && runs[0].tools == ["run_applescript"] && runs[0].questionsAsked == 1)
    }

    @Test(
        "each way a run ends is told apart",
        arguments: [
            (AuditEntry.Kind.reply, "completed", AuditRun.Outcome.completed), (.failure, "failed", .failed),
            (.failure, "cancelled", .cancelled), (.failure, "limit", .stopped), (.failure, "timeout", .stopped),
            (.failure, "refused", .refused), (.failure, "declined", .declined), (.reply, "limit", .stopped),
        ]
    )
    func outcomes(kind: AuditEntry.Kind, word: String, expected: AuditRun.Outcome) {
        let run = UUID()
        let runs = AuditGrouping.runs(from: [
            entry(run, .command, at: 0, detail: "x"), entry(run, kind, at: 1, outcome: word, detail: "why"),
        ])
        #expect(runs.first?.outcome == expected)
    }

    @Test("a run with no result, where the app quit mid-command, is shown as unfinished")
    func unfinished() {
        let run = UUID()
        let runs = AuditGrouping.runs(from: [
            entry(run, .command, at: 0, detail: "x"), entry(run, .toolProposed, at: 1, tool: "open_app"),
        ])
        #expect(runs.first?.outcome == .unfinished)
        #expect(runs.first?.reply == nil)
    }

    @Test("a run whose first lines were rotated away still shows, with no command text")
    func missingCommand() {
        let run = UUID()
        let runs = AuditGrouping.runs(from: [
            entry(run, .toolResult, at: 5, tool: "open_app", outcome: "ok"),
            entry(run, .reply, at: 6, outcome: "completed", detail: "Done."),
        ])
        #expect(runs.first?.command.isEmpty == true)
        #expect(runs.first?.reply == "Done.")
    }

    @Test("a tool asked for twice is listed once; a blank reply is no reply")
    func distinctTools() {
        let run = UUID()
        let runs = AuditGrouping.runs(from: [
            entry(run, .command, at: 0, detail: "x"), entry(run, .toolProposed, at: 1, tool: "a"),
            entry(run, .toolProposed, at: 2, tool: "b"), entry(run, .toolProposed, at: 3, tool: "a"),
            entry(run, .reply, at: 4, outcome: "completed", detail: ""),
        ])
        #expect(runs.first?.tools == ["a", "b"])
        #expect(runs.first?.reply == nil)
    }

    @Test("an empty trail has no runs")
    func empty() { #expect(AuditGrouping.runs(from: []).isEmpty) }
}
