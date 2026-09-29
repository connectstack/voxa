import Foundation
import Testing
import VoxaCore
@testable import VoxaSettings
import VoxaTestSupport

@MainActor
@Suite("Audit viewer")
struct AuditViewerModelTests {
    private func entries(runs: Int, startingAt base: Double = 0) -> [AuditEntry] {
        (0..<runs).flatMap { index -> [AuditEntry] in
            let run = UUID()
            let time = Date(timeIntervalSince1970: 1_800_000_000 + base + Double(index) * 100)
            return [
                AuditEntry(timestamp: time, runID: run, kind: .command, detail: "command \(index)"),
                AuditEntry(
                    timestamp: time + 1,
                    runID: run,
                    kind: .toolProposed,
                    tool: index.isMultiple(of: 2) ? "open_app" : "clipboard_read"
                ),
                AuditEntry(timestamp: time + 2, runID: run, kind: .reply, outcome: "completed", detail: "reply \(index)"),
            ]
        }
    }

    @Test("it loads the trail as commands, newest first, with how much room it takes")
    func loads() async {
        let log = RecordingAuditLog(entries(runs: 3))
        let model = AuditViewerModel(audit: log)
        await model.reload()
        #expect(model.runs.map(\.command) == ["command 2", "command 1", "command 0"])
        #expect(model.totalRuns == 3)
        #expect(model.sizeBytes > 0)
        #expect(!model.isLoading)
    }

    @Test("a search matches what was said, the reply, and the tools used, by name or by title")
    func search() async {
        let model = AuditViewerModel(audit: RecordingAuditLog(entries(runs: 4)))
        await model.reload()

        model.filter = "command 3"
        #expect(model.visibleRuns.map(\.command) == ["command 3"])
        model.filter = "REPLY 1"
        #expect(model.visibleRuns.map(\.command) == ["command 1"])
        model.filter = "clipboard_read"
        #expect(Set(model.visibleRuns.map(\.command)) == ["command 1", "command 3"])
        model.filter = "Read the clipboard"
        #expect(Set(model.visibleRuns.map(\.command)) == ["command 1", "command 3"], "by the name the Tools tab uses")
        model.filter = "  "
        #expect(model.visibleRuns.count == 4, "a blank search shows everything")
        model.filter = "nothing like this"
        #expect(model.visibleRuns.isEmpty)
    }

    @Test("a long history is cut to the newest commands, and the total still says how many there are")
    func capped() async {
        let model = AuditViewerModel(audit: RecordingAuditLog(entries(runs: AuditViewerModel.maxRuns + 25)))
        await model.reload()
        #expect(model.runs.count == AuditViewerModel.maxRuns)
        #expect(model.totalRuns == AuditViewerModel.maxRuns + 25)
        #expect(model.runs.first?.command == "command \(AuditViewerModel.maxRuns + 24)")
    }

    @Test("clearing empties the trail and the list")
    func clears() async {
        let log = RecordingAuditLog(entries(runs: 2))
        let model = AuditViewerModel(audit: log)
        await model.reload()
        #expect(await model.clear())
        #expect(model.runs.isEmpty && model.totalRuns == 0 && model.error == nil)
        #expect(await log.clearCount == 1)
    }

    @Test("if the trail can't be deleted, it says so in plain words and keeps showing what is still there")
    func clearFails() async {
        struct Locked: Error, LocalizedError { var errorDescription: String? { "The file is locked." } }
        let log = RecordingAuditLog(entries(runs: 2))
        await log.setClearFailure(Locked())
        let model = AuditViewerModel(audit: log)
        await model.reload()
        #expect(await !model.clear())
        #expect(model.error == L10n.HistoryUI.clearFailed("The file is locked."))
        #expect(model.totalRuns == 2)
    }

    @Test("every kind of entry has a plain-language line, and none is blank")
    func describesEverything() {
        let run = UUID()
        let samples: [AuditEntry] = [
            AuditEntry(runID: run, kind: .command, detail: "open safari"),
            AuditEntry(runID: run, kind: .toolProposed, tool: "open_app"),
            AuditEntry(runID: run, kind: .policyDecision, tool: "open_app", outcome: "allow"),
            AuditEntry(runID: run, kind: .policyDecision, tool: "open_app", outcome: "notice"),
            AuditEntry(runID: run, kind: .policyDecision, tool: "run_applescript", outcome: "confirm"),
            AuditEntry(runID: run, kind: .policyDecision, tool: "run_applescript", outcome: "deny", detail: "not allowed"),
            AuditEntry(runID: run, kind: .policyDecision, tool: "x", outcome: "invalid", detail: "bad arguments"),
            AuditEntry(runID: run, kind: .confirmation, outcome: "approved"),
            AuditEntry(runID: run, kind: .confirmation, outcome: "denied"),
            AuditEntry(runID: run, kind: .confirmation, outcome: "timeout"),
            AuditEntry(runID: run, kind: .confirmation, outcome: "cancelled"),
            AuditEntry(runID: run, kind: .toolResult, tool: "open_app", outcome: "ok"),
            AuditEntry(runID: run, kind: .toolResult, tool: "open_app", outcome: "error"),
            AuditEntry(runID: run, kind: .permission, tool: "calendar_list_events", outcome: "denied"),
            AuditEntry(runID: run, kind: .reply, outcome: "completed", detail: "Done."),
            AuditEntry(runID: run, kind: .failure, outcome: "failed", detail: "Ollama isn't running"),
        ]
        let lines = samples.map(L10n.HistoryUI.describe)
        #expect(lines.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(Set(lines).count == lines.count, "each says something different")
        #expect(lines[1] == "Asked to use “Open apps”", "tools are named the way the Tools tab names them")
        #expect(lines[5].contains("not allowed"))
    }

    @Test("every way a command can end has a label")
    func outcomeLabels() {
        let outcomes: [AuditRun.Outcome] = [.completed, .cancelled, .failed, .stopped, .refused, .declined, .unfinished]
        #expect(Set(outcomes.map(L10n.HistoryUI.outcome)).count == outcomes.count)
    }
}
