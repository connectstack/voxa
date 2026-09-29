import Foundation
import VoxaCore
import VoxaSpeech
@preconcurrency import WhisperKit

/// Fetches a Whisper model and gets it ready. This is the only place that touches the network, and it runs only when a person
/// presses Download.
///
/// Two steps, because a model that has merely arrived isn't yet usable: first its files are downloaded (a few hundred megabytes),
/// then it is loaded once, which makes Core ML compile it for this Mac's chip (a minute the first time, quick ever after) and
/// fetches the small file that maps words to numbers. Only then is it marked ready.
struct WhisperKitInstaller: Sendable {
    let storage: WhisperStorage

    func installed() -> Set<String> {
        storage.readyModels()
    }

    func install(_ id: String, progress: WhisperModelsModel.Progress) async throws {
        guard WhisperModelCatalog.model(id) != nil else { throw SpeechError.whisperFailed("That model isn't one Voxa offers.") }
        let base = storage.base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let folder = try await abandoningOnCancel {
            try await WhisperKit.download(variant: id, downloadBase: base, progressCallback: { progress.downloading($0.fractionCompleted) })
        }
        progress.downloading(1)
        try Task.checkCancellation()

        progress.preparing()
        try await abandoningOnCancel {
            let config = WhisperKitConfig(
                model: id,
                downloadBase: base,
                modelFolder: folder.path,
                tokenizerFolder: base,
                verbose: false,
                logLevel: .none,
                prewarm: true,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)
            await kit.unloadModels()
        }
        try Task.checkCancellation()
        try storage.markReady(id, folder: folder)
    }

    func remove(_ id: String) throws {
        try storage.remove(id)
    }
}

// MARK: - What the app uses

/// The Whisper engine, as the app sees it: a recognizer to hand to the speech provider, and the work behind Settings' model list.
public struct WhisperSupport: Sendable {
    private let host: WhisperEngineHost
    private let installer: WhisperKitInstaller

    /// - Parameter folder: Where models are kept. The default is Voxa's own folder in Application Support; tests use another.
    public init(folder: URL? = nil) {
        let storage = folder.map { WhisperStorage(base: $0) } ?? .standard
        host = WhisperEngineHost(storage: storage)
        installer = WhisperKitInstaller(storage: storage)
    }

    /// The recognizer for the model chosen in the settings.
    public func recognizer(for settings: AppSettings) -> any SpeechRecognizer {
        WhisperRecognizer(model: settings.whisperModel, transcribers: host)
    }

    /// What Settings' model list does: look at what is on disk, download, remove.
    public var modelActions: WhisperModelsModel.Actions {
        let installer = installer
        return WhisperModelsModel.Actions(
            installed: { installer.installed() },
            install: { id, progress in try await installer.install(id, progress: progress) },
            remove: { id in try installer.remove(id) }
        )
    }
}
