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

/// The "Safety" tab: how eagerly Voxa asks, and the limits on one command.
struct SafetySettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Picker(L10n.SettingsModel.strictness, selection: $store.current.confirmationStrictness) {
                    Text(L10n.SettingsModel.strictnessStandard).tag(ConfirmationStrictness.standard)
                    Text(L10n.SettingsModel.strictnessStrict).tag(ConfirmationStrictness.strict)
                    Text(L10n.SettingsModel.strictnessParanoid).tag(ConfirmationStrictness.paranoid)
                }
                Text(L10n.SettingsModel.strictnessHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $store.current.followUpWindowSeconds, in: 0...600, step: 30) {
                    Text(L10n.SettingsModel.followUp(store.current.followUpWindowSeconds))
                }
                Text(L10n.SettingsModel.followUpHelp).font(.caption).foregroundStyle(.secondary)
                Stepper(value: $store.current.maxAgentSteps, in: 1...25) {
                    Text(L10n.SettingsModel.maxSteps(store.current.maxAgentSteps))
                }
            }
        }
        .formStyle(.grouped)
    }
}
