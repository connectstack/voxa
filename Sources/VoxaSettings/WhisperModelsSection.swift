import SwiftUI
import VoxaCore
import VoxaSpeech

/// The list of Whisper models in Settings → General: what each is, how much it is to download, and the button that fits
/// wherever it has got to. Nothing is fetched until Download is pressed.
struct WhisperModelsSection: View {
    @Bindable var store: SettingsStore
    let models: WhisperModelsModel

    var body: some View {
        Section(L10n.WhisperUI.section) {
            Text(L10n.WhisperUI.intro).font(.caption).foregroundStyle(.secondary)
            ForEach(WhisperModelCatalog.all) { model in
                WhisperModelRow(
                    model: model,
                    isChosen: store.current.whisperModel == model.id,
                    state: models.state(of: model.id),
                    isBusy: models.isBusy,
                    choose: { store.current.whisperModel = model.id },
                    download: { models.download(model.id) },
                    cancel: { models.cancel(model.id) },
                    remove: { models.remove(model.id) }
                )
            }
            if chosenIsEnglishOnly, !languageIsEnglish {
                Text(L10n.WhisperUI.englishOnlyNote).font(.caption).foregroundStyle(.orange)
            }
            if !models.hasInstalledModel {
                Text(L10n.WhisperUI.notInstalledHint).font(.caption).foregroundStyle(.orange)
            }
        }
        .task { await models.refresh() }
    }

    private var chosenIsEnglishOnly: Bool {
        WhisperModelCatalog.model(store.current.whisperModel)?.isEnglishOnly ?? false
    }

    private var languageIsEnglish: Bool {
        store.current.locale.language.languageCode?.identifier == "en"
    }
}

/// One model: its name and size, where it stands, and what can be done with it.
struct WhisperModelRow: View {
    let model: WhisperModel
    let isChosen: Bool
    let state: WhisperModelsModel.State
    let isBusy: Bool
    let choose: () -> Void
    let download: () -> Void
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.WhisperUI.modelTitle(name: model.name, englishOnly: model.isEnglishOnly))
                    .font(.body.weight(.medium))
                status
            }
            Spacer(minLength: 8)
            controls
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .notInstalled:
            Text(L10n.WhisperUI.size(model.approximateMegabytes)).font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 110)
                Text(L10n.WhisperUI.downloading(Int((fraction * 100).rounded()))).font(.caption).foregroundStyle(.secondary)
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.WhisperUI.preparing).font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Text(L10n.WhisperUI.ready).font(.caption).foregroundStyle(.green)
        case .failed(let reason):
            Text(L10n.WhisperUI.failed(reason)).font(.caption).foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .notInstalled:
            Button(L10n.WhisperUI.download, action: download).disabled(isBusy)
        case .failed:
            Button(L10n.WhisperUI.retry, action: download).disabled(isBusy)
        case .downloading, .preparing:
            Button(L10n.WhisperUI.cancel, action: cancel)
        case .ready:
            HStack(spacing: 8) {
                if isChosen {
                    Text(L10n.WhisperUI.inUse).font(.caption.weight(.medium)).foregroundStyle(.tint)
                } else {
                    Button(L10n.WhisperUI.useThisOne, action: choose)
                }
                Button(L10n.WhisperUI.remove, action: remove).disabled(isBusy)
            }
        }
    }
}

/// The model list on its own, at the width of the Settings window, for pictures of it (`voxa-dev hud-snapshots`).
public struct WhisperModelsPreview: View {
    let store: SettingsStore
    let models: WhisperModelsModel

    public init(store: SettingsStore, models: WhisperModelsModel) {
        self.store = store
        self.models = models
    }

    public var body: some View {
        Form { WhisperModelsSection(store: store, models: models) }
            .formStyle(.grouped)
            .frame(width: SettingsView.contentSize.width, height: 430)
    }
}
