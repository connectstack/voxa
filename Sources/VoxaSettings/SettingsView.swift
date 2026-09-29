import SwiftUI
import VoxaCore

/// Which tab of Settings is showing. The window controller holds it, so other parts of the app (an error's "Open Settings"
/// button) can send the user to the tab where the problem is put right.
@MainActor
@Observable
public final class SettingsNavigation {
    public var tab: SettingsView.Tab

    public init(tab: SettingsView.Tab = .general) {
        self.tab = tab
    }
}

/// The Settings window's content: general (shortcut, speech, voice), model (provider, key, model), tools (a switch for each),
/// permissions, safety (confirmation strictness and limits) and history (the audit trail).
public struct SettingsView: View {
    /// The window is a fixed size (each tab's form scrolls if it ever outgrows it), which keeps window sizing out of Auto
    /// Layout entirely; see `SettingsWindowController`.
    public static let contentSize = CGSize(width: 560, height: 500)

    @Bindable private var store: SettingsStore
    @Bindable private var navigation: SettingsNavigation
    private let services: SettingsServices

    public init(
        store: SettingsStore,
        services: SettingsServices = .inert,
        navigation: SettingsNavigation = SettingsNavigation()
    ) {
        self.store = store
        self.services = services
        self.navigation = navigation
    }

    public enum Tab: String, CaseIterable, Identifiable {
        case general, model, tools, permissions, safety, history
        public var id: String { rawValue }

        var title: String {
            switch self {
            case .general: L10n.Settings.general
            case .model: L10n.SettingsModel.tab
            case .tools: L10n.ToolsUI.tab
            case .permissions: L10n.PermissionsUI.tab
            case .safety: L10n.SettingsModel.safetyTab
            case .history: L10n.HistoryUI.tab
            }
        }
    }

    /// A plain SwiftUI tab bar above the page rather than a `TabView` or an AppKit segmented control: on macOS 26 a
    /// `TabView` in a hosted window can move its tabs into a window toolbar and change the window's height, and this
    /// window's size is fixed on purpose.
    public var body: some View {
        VStack(spacing: 0) {
            TabBar(selection: $navigation.tab)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)

            switch navigation.tab {
            case .general: GeneralSettingsView(store: store, services: services)
            case .model: ModelSettingsView(store: store, services: services)
            case .tools: ToolsSettingsView(store: store, tools: services.tools, permissions: services.permissions)
            case .permissions: PermissionsSettingsView(model: services.permissions)
            case .safety: SafetySettingsView(store: store)
            case .history: HistorySettingsView(audit: services.audit)
            }
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
    }
}

private struct TabBar: View {
    @Binding var selection: SettingsView.Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsView.Tab.allCases) { tab in
                let isSelected = selection == tab
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(
                                isSelected ? Color.primary.opacity(0.13) : Color.clear
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}
