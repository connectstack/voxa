import Foundation
import VoxaCore

/// Where Whisper models live on this Mac, and which of them are ready to use.
///
/// Models go in Voxa's own folder in Application Support, never in Documents (where the library would put them by default, and
/// where macOS would ask for access). A model counts as *ready* only when a small marker says its download finished and it was
/// prepared for this Mac's chip, so a download that was interrupted is never mistaken for one that works.
struct WhisperStorage: Sendable {
    /// The folder everything is kept in.
    let base: URL

    /// `~/Library/Application Support/Voxa/Models/whisper`.
    static var standard: WhisperStorage {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return WhisperStorage(base: support.appendingPathComponent("Voxa/Models/whisper", isDirectory: true))
    }

    private struct Marker: Codable {
        var model: String
        /// The folder the model's files are in, as the library reported it when the download finished.
        var folder: String
        var preparedAt: Date
    }

    private var markers: URL { base.appendingPathComponent("ready", isDirectory: true) }

    private func markerURL(_ id: String) -> URL {
        // The id is one of the catalog's, but it names a file, so anything else is refused.
        markers.appendingPathComponent(id.filter { $0.isLetter || $0.isNumber || $0 == "." } + ".json")
    }

    /// The folder holding a ready model's files, or nil when it isn't ready.
    func folder(for id: String) -> URL? {
        guard WhisperModelCatalog.model(id) != nil,
            let data = try? Data(contentsOf: markerURL(id)),
            let marker = try? JSONDecoder().decode(Marker.self, from: data),
            marker.model == id,
            FileManager.default.fileExists(atPath: marker.folder)
        else { return nil }
        return URL(fileURLWithPath: marker.folder, isDirectory: true)
    }

    func isReady(_ id: String) -> Bool { folder(for: id) != nil }

    /// The ids of every model that is ready.
    func readyModels() -> Set<String> {
        Set(WhisperModelCatalog.all.map(\.id).filter(isReady))
    }

    func markReady(_ id: String, folder: URL) throws {
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let marker = Marker(model: id, folder: folder.path, preparedAt: Date())
        try JSONEncoder().encode(marker).write(to: markerURL(id), options: .atomic)
    }

    /// Deletes a model: its files and its marker. These are files Voxa downloaded itself, at the person's request.
    func remove(_ id: String) throws {
        if let folder = folder(for: id) { try FileManager.default.removeItem(at: folder) }
        try? FileManager.default.removeItem(at: markerURL(id))
    }
}
