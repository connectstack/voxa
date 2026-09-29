import SwiftUI
import VoxaCore
import VoxaPermissions

/// The Permissions tab: what Voxa may use, whether it can right now, and a button that fixes it.
struct PermissionsSettingsView: View {
    let model: PermissionsModel

    var body: some View {
        Form {
            Section {
                Text(L10n.PermissionsUI.intro).font(.callout).foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.kinds) { kind in
                    PermissionRow(kind: kind, model: model)
                }
            }
        }
        .formStyle(.grouped)
        .permissionPolling(model)
    }
}

/// One permission: an icon, what it is for, whether it is on, and what to press. Also used by the welcome walkthrough.
struct PermissionRow: View {
    let kind: PermissionKind
    let model: PermissionsModel

    private var status: PermissionStatus { model.status(of: kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName).font(.body.weight(.medium))
                Text(L10n.PermissionsUI.purpose(for: kind)).font(.caption).foregroundStyle(.secondary)
                if let note {
                    Text(note.text).font(.caption).foregroundStyle(note.isWarning ? Color.orange : Color.secondary)
                }
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(status: status, isPerApp: kind.isPerApp)
                actionButtons
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var note: (text: String, isWarning: Bool)? {
        switch status {
        case .denied: (L10n.PermissionsUI.deniedNote, true)
        case .restricted: (L10n.PermissionsUI.restrictedNote, true)
        case .notDetermined where kind.isPerApp: (L10n.PermissionsUI.automationNote, true)
        case .notDetermined where kind.isGrantedInSystemSettings: (L10n.PermissionsUI.switchOnNote(kind.displayName), false)
        default: nil
        }
    }

    private var actionButtons: some View {
        ForEach(model.actions(for: kind), id: \.self) { action in
            switch action {
            case .none:
                EmptyView()
            case .allow:
                Button(L10n.PermissionsUI.allow) { Task { await model.perform(.allow, for: kind) } }
                    .disabled(model.requesting != nil)
            case .openSystemSettings:
                Button(L10n.PermissionsUI.openSystemSettings) { model.openSystemSettings(for: kind) }
            }
        }
    }
}

/// A small capsule that says whether a permission is on.
struct StatusPill: View {
    let status: PermissionStatus
    var isPerApp = false

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var label: String {
        // Automation has no single answer: macOS asks for each app in turn.
        isPerApp && status == .notDetermined ? "Per app" : L10n.PermissionsUI.statusLabel(status)
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .notDetermined: isPerApp ? .secondary : .orange
        case .denied: .red
        case .restricted: .secondary
        }
    }
}

extension View {
    /// Re-reads the permissions once a second while the view is on screen, and when Voxa comes to the front: macOS sends no
    /// notification when a switch is flipped in System Settings, so this is how a row turns green when the user comes back.
    func permissionPolling(_ model: PermissionsModel) -> some View {
        modifier(PermissionPolling(model: model))
    }
}

private struct PermissionPolling: ViewModifier {
    let model: PermissionsModel

    func body(content: Content) -> some View {
        content
            .task {
                while !Task.isCancelled {
                    model.refresh()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refresh()
            }
    }
}
