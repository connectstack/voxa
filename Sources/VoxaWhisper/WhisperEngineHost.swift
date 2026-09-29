import Foundation
import VoxaCore
import VoxaSpeech
@preconcurrency import WhisperKit

/// Loads the chosen Whisper model when it is first needed, keeps it in memory while it is being used, and lets it go after a
/// while, because a model takes a few hundred megabytes and a person may not speak to Voxa again for hours.
///
/// It only ever loads a model that is *ready* (see `WhisperStorage`). It never downloads one: what a model needs from the
/// network is fetched when the person presses Download in Settings, not in the middle of a command.
actor WhisperEngineHost: WhisperTranscriberProviding {
    private let storage: WhisperStorage
    private let idleTimeout: Duration

    private var loaded: (id: String, transcriber: WhisperKitTranscriber)?
    private var loading: (id: String, task: Task<WhisperKitTranscriber, any Error>)?
    private var idleTimer: Task<Void, Never>?

    init(storage: WhisperStorage = .standard, idleTimeout: Duration = .seconds(600)) {
        self.storage = storage
        self.idleTimeout = idleTimeout
    }

    func transcriber(forModel id: String) async throws -> any WhisperTranscribing {
        guard let folder = storage.folder(for: id) else { throw SpeechError.whisperModelMissing(name: id) }
        if let loaded, loaded.id == id {
            scheduleUnload()
            return loaded.transcriber
        }
        if let loading, loading.id == id { return try await loading.task.value }

        // A different model was in memory: it goes.
        if let old = loaded?.transcriber {
            loaded = nil
            await old.unload()
        }
        let base = storage.base
        let task = Task { try await Self.load(id, from: folder, base: base) }
        loading = (id, task)
        do {
            let transcriber = try await task.value
            loaded = (id, transcriber)
            loading = nil
            scheduleUnload()
            return transcriber
        } catch {
            loading = nil
            throw error
        }
    }

    private static func load(_ id: String, from folder: URL, base: URL) async throws -> WhisperKitTranscriber {
        let config = WhisperKitConfig(
            model: id,
            downloadBase: base,
            modelFolder: folder.path,
            tokenizerFolder: base,
            verbose: false,
            logLevel: .none,
            prewarm: false,
            load: true,
            download: false
        )
        do {
            return WhisperKitTranscriber(kit: try await WhisperKit(config))
        } catch {
            throw SpeechError.whisperFailed(error.localizedDescription)
        }
    }

    // MARK: Letting go

    private func scheduleUnload() {
        idleTimer?.cancel()
        let timeout = idleTimeout
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.unloadIfIdle()
        }
    }

    private func unloadIfIdle() async {
        guard let old = loaded?.transcriber else { return }
        loaded = nil
        await old.unload()
    }
}
