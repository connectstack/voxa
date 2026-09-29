import KeyboardShortcuts
import SwiftUI
import VoxaCore
import VoxaLLM
import VoxaSpeech

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

/// The Settings window's content: general (shortcut and speech), model (API key, model, thinking) and safety
/// (confirmation strictness and limits). Tabs for tools and the audit log arrive with the features they configure.
public struct SettingsView: View {
    /// The window is a fixed size (each tab's form scrolls if it ever outgrows it), which keeps window sizing out of Auto
    /// Layout entirely; see `SettingsWindowController`.
    public static let contentSize = CGSize(width: 520, height: 480)

    @Bindable private var store: SettingsStore
    @Bindable private var navigation: SettingsNavigation
    private let services: ProviderServices

    public init(
        store: SettingsStore,
        services: ProviderServices = .inert,
        navigation: SettingsNavigation = SettingsNavigation()
    ) {
        self.store = store
        self.services = services
        self.navigation = navigation
    }

    public enum Tab: String, CaseIterable, Identifiable {
        case general, model, safety
        public var id: String { rawValue }

        var title: String {
            switch self {
            case .general: L10n.Settings.general
            case .model: L10n.SettingsModel.tab
            case .safety: L10n.SettingsModel.safetyTab
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
            case .general: GeneralSettingsView(store: store)
            case .model: ModelSettingsView(store: store, services: services)
            case .safety: SafetySettingsView(store: store)
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

/// The shortcut and speech recognition settings.
struct GeneralSettingsView: View {
    @Bindable var store: SettingsStore
    @State private var languages: [SpeechLanguage] = []

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder(for: .pushToTalk) {
                    Text(L10n.Settings.pushToTalk)
                }
                Text(L10n.Settings.pushToTalkHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(L10n.Settings.speechEngine, selection: $store.current.speechEngine) {
                    Text(L10n.Settings.engineAutomatic).tag(SpeechEngineKind.appleAutomatic)
                    Text(L10n.Settings.engineClassic).tag(SpeechEngineKind.appleClassic)
                }
                Picker(L10n.Settings.language, selection: $store.current.localeIdentifier) {
                    ForEach(languageChoices) { language in
                        Text(language.name).tag(language.id)
                    }
                }
                Text(L10n.Settings.engineHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L10n.Settings.downloadModel, isOn: $store.current.downloadSpeechModel)
                    .disabled(store.current.speechEngine == .appleClassic)
                Text(L10n.Settings.downloadModelHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            // Building the list instantiates a recognizer per language, so keep it off the main thread.
            languages = await Task.detached { SpeechLanguages.available() }.value
        }
    }

    /// The system's languages, plus the current selection if the system doesn't list it (so the picker never
    /// shows a blank value).
    private var languageChoices: [SpeechLanguage] {
        let selected = store.current.localeIdentifier
        guard !languages.contains(where: { $0.id == selected }) else { return languages }
        let name = Locale.current.localizedString(forIdentifier: selected) ?? selected
        return [SpeechLanguage(id: selected, name: name, supportsOnDevice: false)] + languages
    }
}
