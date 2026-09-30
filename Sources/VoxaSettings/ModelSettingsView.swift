import SwiftUI
import VoxaCore
import VoxaLLM

/// The "Model" tab: which provider answers, and that provider's key or server, model and thinking.
struct ModelSettingsView: View {
    @Bindable var store: SettingsStore
    let services: SettingsServices

    var body: some View {
        Form {
            Section {
                Picker(L10n.SettingsProvider.provider, selection: $store.current.provider) {
                    ForEach(ModelProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text(L10n.SettingsProvider.summary(for: store.current.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch store.current.provider {
            case .anthropic:
                ProviderKeySection(provider: .anthropic, services: services)
                ModelFieldSection(store: store, provider: .anthropic)
            case .openAI:
                ProviderKeySection(provider: .openAI, services: services)
                ModelFieldSection(store: store, provider: .openAI)
            case .ollama:
                OllamaSection(store: store, services: services)
            }
        }
        .formStyle(.grouped)
    }
}
