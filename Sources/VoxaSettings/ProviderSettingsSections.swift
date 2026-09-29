import SwiftUI
import VoxaCore
import VoxaLLM

/// The API key for Claude or OpenAI: entered once, kept in the Keychain, never shown again, with a button that makes one
/// tiny real request to check it works.
struct ProviderKeySection: View {
    let provider: ModelProvider
    @State private var form: APIKeyFormModel

    init(provider: ModelProvider, services: ProviderServices) {
        self.provider = provider
        let keys = services.keys[provider] ?? InMemoryAPIKeyStore()
        _form = State(
            initialValue: APIKeyFormModel(keys: keys, testConnection: { await services.testConnection(provider) })
        )
    }

    var body: some View {
        Section(L10n.SettingsProvider.keyTitle(for: provider)) {
            if form.showsEntryField {
                entryField
            } else {
                savedKey
            }
            if let error = form.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Text(L10n.SettingsProvider.privacy(for: provider))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { form.refresh() }
    }

    private var savedKey: some View {
        Group {
            Label(L10n.SettingsModel.keySaved, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            HStack {
                Button(L10n.SettingsModel.replace) { form.beginReplacing() }
                Button(L10n.SettingsModel.remove, role: .destructive) { form.remove() }
                Spacer()
                ConnectionStatus(connection: form.connection) { Task { await form.test() } }
            }
        }
    }

    private var entryField: some View {
        Group {
            SecureField(L10n.SettingsProvider.keyPlaceholder(for: provider), text: $form.input)
                .textContentType(.password)
                .onSubmit { form.save() }
            HStack {
                if !form.hasKey {
                    Text(L10n.SettingsModel.noKey).foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                if form.isReplacing {
                    Button(L10n.SettingsModel.cancel) { form.cancelReplacing() }
                }
                Button(L10n.SettingsModel.save) { form.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!form.canSave)
            }
        }
    }
}

/// The result of the last connection test, and the button that runs another.
struct ConnectionStatus: View {
    let connection: APIKeyFormModel.Connection
    let test: () -> Void

    var body: some View {
        switch connection {
        case .idle:
            testButton
        case .testing:
            Text(L10n.SettingsModel.testing).foregroundStyle(.secondary).font(.caption)
        case .connected:
            Text(L10n.SettingsModel.connected).foregroundStyle(.green).font(.caption)
            testButton
        case .failed(let message):
            Text(message).foregroundStyle(.red).font(.caption).lineLimit(2)
            testButton
        }
    }

    private var testButton: some View {
        Button(L10n.SettingsModel.testConnection, action: test)
    }
}

/// The model name, and for OpenAI the server address, then how hard the model thinks.
struct ModelFieldSection: View {
    @Bindable var store: SettingsStore
    let provider: ModelProvider

    private var model: Binding<String> {
        provider == .openAI ? $store.current.openAIModel : $store.current.model
    }

    private var defaultModel: String {
        provider == .openAI ? AppSettings.defaultOpenAIModel : AppSettings.defaultModel
    }

    var body: some View {
        Section {
            HStack {
                TextField(L10n.SettingsModel.modelName, text: model)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.SettingsModel.resetModel) { model.wrappedValue = defaultModel }
                    .disabled(model.wrappedValue == defaultModel)
            }
            Text(L10n.SettingsProvider.modelHelp(for: provider)).font(.caption).foregroundStyle(.secondary)

            if provider == .openAI {
                HStack {
                    TextField(L10n.SettingsProvider.serverAddress, text: $store.current.openAIBaseURL)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.SettingsModel.resetModel) { store.current.openAIBaseURL = AppSettings.defaultOpenAIBaseURL }
                        .disabled(store.current.openAIBaseURL == AppSettings.defaultOpenAIBaseURL)
                }
                Text(L10n.SettingsProvider.openAIAddressHelp).font(.caption).foregroundStyle(.secondary)
            }
            EffortPicker(store: store, provider: provider)
        }
    }
}

/// How hard the model thinks: quick, balanced or thorough.
struct EffortPicker: View {
    @Bindable var store: SettingsStore
    let provider: ModelProvider

    var body: some View {
        Group {
            Picker(L10n.SettingsModel.effort, selection: $store.current.effort) {
                Text(L10n.SettingsModel.effortLow).tag(ReasoningEffort.low)
                Text(L10n.SettingsModel.effortMedium).tag(ReasoningEffort.medium)
                Text(L10n.SettingsModel.effortHigh).tag(ReasoningEffort.high)
            }
            Text(L10n.SettingsProvider.effortHelp(for: provider)).font(.caption).foregroundStyle(.secondary)
        }
    }
}
