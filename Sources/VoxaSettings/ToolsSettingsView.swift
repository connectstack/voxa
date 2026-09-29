import SwiftUI
import VoxaCore
import VoxaPermissions

/// The Tools tab: every tool Voxa has, with a switch for each. A tool that's off is hidden from the model and refused if
/// called anyway.
struct ToolsSettingsView: View {
    @Bindable var store: SettingsStore
    let tools: [ToolInfo]
    let permissions: PermissionsModel

    var body: some View {
        Form {
            Section {
                Text(L10n.ToolsUI.intro).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.category) { group in
                Section(group.category.title) {
                    ForEach(group.tools) { tool in
                        ToolRow(tool: tool, isOn: binding(for: tool), permissions: permissions)
                    }
                }
            }
            Section {
                Text(L10n.ToolsUI.footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .permissionPolling(permissions)
    }

    private var groups: [(category: L10n.ToolsUI.Category, tools: [ToolInfo])] {
        L10n.ToolsUI.Category.allCases.compactMap { category in
            let members = tools.filter { L10n.ToolsUI.category(for: $0.name) == category }
            return members.isEmpty ? nil : (category, members)
        }
    }

    private func binding(for tool: ToolInfo) -> Binding<Bool> {
        Binding(
            get: { store.current.isToolEnabled(tool.name) },
            set: { store.current.setTool(tool.name, enabled: $0) }
        )
    }
}

private struct ToolRow: View {
    let tool: ToolInfo
    @Binding var isOn: Bool
    let permissions: PermissionsModel

    /// A permission this tool needs that isn't on yet, worth a word beside the switch.
    private var missing: PermissionKind? {
        tool.permissions.first { !$0.isPerApp && !permissions.status(of: $0).isGranted }
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(L10n.ToolsUI.title(for: tool.name))
                    RiskBadge(risk: tool.risk)
                }
                Text(L10n.ToolsUI.blurb(for: tool.name, fallback: firstSentence(tool.summary)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isOn, let missing {
                    Label(L10n.ToolsUI.needs(missing.displayName), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func firstSentence(_ text: String) -> String {
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return text }
        return String(text[...end])
    }
}

private struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(L10n.ToolsUI.riskLabel(risk))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch risk {
        case .readOnly: .secondary
        case .reversible: .blue
        case .sensitive: .orange
        }
    }
}
