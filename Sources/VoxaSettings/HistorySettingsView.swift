import AppKit
import SwiftUI
import VoxaCore

/// The History tab: every command and what Voxa did about it, with a search, and a button that deletes it all.
struct HistorySettingsView: View {
    @State private var model: AuditViewerModel
    @State private var confirmingClear = false

    init(audit: any AuditReading) {
        _model = State(initialValue: AuditViewerModel(audit: audit))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .task { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reload() }
        }
        .confirmationDialog(L10n.HistoryUI.clearTitle, isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(L10n.HistoryUI.clearConfirm, role: .destructive) { Task { await model.clear() } }
            Button(L10n.SettingsModel.cancel, role: .cancel) {}
        } message: {
            Text(L10n.HistoryUI.clearMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.HistoryUI.intro).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L10n.HistoryUI.search, text: $model.filter).textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if model.visibleRuns.isEmpty {
            VStack {
                Spacer()
                Text(model.runs.isEmpty ? L10n.HistoryUI.empty : L10n.HistoryUI.noMatches)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(model.visibleRuns) { run in
                RunRow(run: run)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(L10n.HistoryUI.summary(commands: model.totalRuns, size: Self.sizeText(model.sizeBytes)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.HistoryUI.refresh) { Task { await model.reload() } }
                Button(L10n.HistoryUI.showInFinder) { reveal() }
                    .disabled(model.location == nil)
                Button(L10n.HistoryUI.clear, role: .destructive) { confirmingClear = true }
                    .disabled(model.totalRuns == 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func reveal() {
        guard let url = model.location else { return }
        // The file may not exist yet; its folder always does once anything has been recorded.
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// One command, closed to a line and open to its whole story.
private struct RunRow: View {
    let run: AuditRun

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(run.entries, id: \.id) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text(L10n.HistoryUI.describe(entry)).font(.caption).textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.command.isEmpty ? L10n.HistoryUI.unknownCommand : run.command).lineLimit(2)
                    Text("\(run.start.formatted(date: .abbreviated, time: .shortened)) · \(L10n.HistoryUI.outcome(run.outcome))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbol: String {
        switch run.outcome {
        case .completed: "checkmark.circle.fill"
        case .cancelled: "stop.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "clock.badge.exclamationmark"
        case .refused: "hand.raised.fill"
        case .declined: "xmark.circle"
        case .unfinished: "questionmark.circle"
        }
    }

    private var color: Color {
        switch run.outcome {
        case .completed: .green
        case .failed, .stopped: .orange
        default: .secondary
        }
    }
}
