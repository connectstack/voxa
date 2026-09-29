import AppKit
import SwiftUI
import VoxaCore
import VoxaLLM

/// Ollama: the server, the models it has, and what the chosen one can do.
struct OllamaSection: View {
    @Bindable var store: SettingsStore
    let services: ProviderServices

    @State private var server: OllamaSettingsModel
    @State private var connection = APIKeyFormModel.Connection.idle

    init(store: SettingsStore, services: ProviderServices) {
        self.store = store
        self.services = services
        _server = State(initialValue: OllamaSettingsModel(discovery: services.ollama))
    }

    var body: some View {
        Group {
            Section(L10n.Provider.ollama) {
                TextField(L10n.SettingsProvider.ollamaServer, text: $store.current.ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await refresh() } }
                statusRow
                Text(L10n.SettingsProvider.ollamaAddressHelp).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                modelPicker
                modelNotes
                Stepper(value: $store.current.ollamaContextLength, in: 2_048...131_072, step: 2_048) {
                    Text("\(L10n.SettingsProvider.contextLength): \(L10n.SettingsProvider.contextValue(store.current.ollamaContextLength))")
                }
                Text(L10n.SettingsProvider.contextHelp).font(.caption).foregroundStyle(.secondary)
                EffortPicker(store: store, provider: .ollama)
                HStack {
                    Spacer()
                    ConnectionStatus(connection: connection) { Task { await test() } }
                }
            }
        }
        // Looks again whenever the address changes, after a short pause so typing doesn't ask at every key.
        .task(id: store.current.ollamaBaseURL) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await refresh()
        }
        .task(id: store.current.ollamaModel) {
            await server.loadDetails(of: store.current.ollamaModel, address: store.current.ollamaBaseURL)
        }
    }

    // MARK: Server

    private var statusRow: some View {
        HStack {
            switch server.status {
            case .checking:
                ProgressView().controlSize(.small)
                Text(L10n.SettingsProvider.ollamaChecking).foregroundStyle(.secondary)
            case .running(let version):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.SettingsProvider.ollamaRunning(version: version))
            case .notRunning:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(L10n.SettingsProvider.ollamaNotRunning)
            case .problem(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(message)
            }
            Spacer()
            Button(L10n.SettingsProvider.refresh) { Task { await refresh() } }
            Button(L10n.Recovery.openOllama) { services.openOllama() }
        }
        .font(.callout)
    }

    // MARK: Model

    @ViewBuilder
    private var modelPicker: some View {
        if server.models.isEmpty {
            // Nothing to pick from (not running, or nothing installed yet): the name can still be typed.
            TextField(L10n.SettingsModel.modelName, text: $store.current.ollamaModel, prompt: Text(L10n.SettingsProvider.modelPlaceholder))
                .textFieldStyle(.roundedBorder)
            if server.isRunning {
                Text(L10n.SettingsProvider.noModelsInstalled).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Picker(L10n.SettingsModel.modelName, selection: $store.current.ollamaModel) {
                if store.current.ollamaModel.isEmpty {
                    Text(L10n.SettingsProvider.chooseModel).tag("")
                } else if server.installed(store.current.ollamaModel) == nil {
                    Text(L10n.SettingsProvider.notInstalled(store.current.ollamaModel)).tag(store.current.ollamaModel)
                }
                ForEach(server.models) { model in
                    Text(model.isCloud ? L10n.SettingsProvider.cloudSuffix(model.name) : model.name).tag(model.name)
                }
            }
        }
    }

    @ViewBuilder
    private var modelNotes: some View {
        let chosen = store.current.ollamaModel
        if let model = server.installed(chosen) {
            if model.isCloud {
                Label(L10n.SettingsProvider.cloudModelWarning, systemImage: "cloud")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let details = server.details, !details.supportsTools {
                Label(L10n.SettingsProvider.cannotUseTools(chosen), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Actions

    private func refresh() async {
        await server.refresh(address: store.current.ollamaBaseURL, chosen: store.current.ollamaModel)
    }

    func test() async {
        connection = .testing
        let failure = await services.testConnection(.ollama)
        connection = failure.map { .failed($0.title) } ?? .connected
        await refresh()
    }
}
