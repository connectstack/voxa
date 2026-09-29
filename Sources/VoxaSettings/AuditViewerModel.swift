import Foundation
import Observation
import VoxaCore

/// What the History tab shows: the audit trail grouped into commands, with a search over them. Kept apart from the view so
/// grouping, searching and clearing are tested without a window.
@MainActor
@Observable
final class AuditViewerModel {
    /// The most commands shown; older ones stay in the file but the list stays quick.
    static let maxRuns = 300

    private(set) var runs: [AuditRun] = []
    private(set) var totalRuns = 0
    private(set) var sizeBytes = 0
    private(set) var isLoading = false
    private(set) var error: String?
    var filter = ""

    @ObservationIgnored private let audit: any AuditReading

    init(audit: any AuditReading) {
        self.audit = audit
    }

    var location: URL? { audit.location }

    /// The runs that match the search: by what was said, the reply, or a tool used (by name or by its title).
    var visibleRuns: [AuditRun] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return runs }
        return runs.filter { run in
            let haystack = [run.command, run.reply ?? ""] + run.tools + run.tools.map(L10n.ToolsUI.title(for:))
            return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func reload() async {
        isLoading = true
        let entries = await audit.readAll()
        let grouped = AuditGrouping.runs(from: entries)
        totalRuns = grouped.count
        runs = Array(grouped.prefix(Self.maxRuns))
        sizeBytes = await audit.sizeOnDisk()
        isLoading = false
    }

    /// Deletes the whole trail. Returns whether it worked; if not, `error` says why.
    @discardableResult
    func clear() async -> Bool {
        do {
            try await audit.clear()
            error = nil
            await reload()
            return true
        } catch {
            self.error = L10n.HistoryUI.clearFailed(error.localizedDescription)
            return false
        }
    }
}
