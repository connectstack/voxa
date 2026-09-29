import Foundation
import Testing
import VoxaCore
@testable import VoxaWhisper

/// A throwaway models folder, so nothing here touches the real one.
private struct Scratch {
    let base: URL
    let storage: WhisperStorage

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-whisper-\(UUID().uuidString)", isDirectory: true)
        storage = WhisperStorage(base: base)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: base) }

    /// A folder that stands in for a downloaded model's files.
    func modelFolder(_ name: String) throws -> URL {
        let folder = base.appendingPathComponent("models/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: folder.appendingPathComponent("weights.bin"))
        return folder
    }
}

@Suite("WhisperStorage")
struct WhisperStorageTests {
    @Test("a model is ready only once it has been marked, and it remembers where its files are")
    func ready() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.modelFolder("openai_whisper-base.en")
        #expect(!scratch.storage.isReady("base.en"), "files that merely exist aren't a finished download")
        try scratch.storage.markReady("base.en", folder: folder)
        #expect(scratch.storage.isReady("base.en"))
        #expect(scratch.storage.folder(for: "base.en")?.path == folder.path)
        #expect(scratch.storage.readyModels() == ["base.en"])
    }

    @Test("a marked model whose files have gone is not ready")
    func filesGone() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.modelFolder("openai_whisper-tiny")
        try scratch.storage.markReady("tiny", folder: folder)
        try FileManager.default.removeItem(at: folder)
        #expect(!scratch.storage.isReady("tiny") && scratch.storage.readyModels().isEmpty)
    }

    @Test("only models Voxa offers can be ready, whatever the marker says")
    func onlyCatalogModels() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.modelFolder("x")
        try scratch.storage.markReady("gigantic", folder: folder)
        #expect(!scratch.storage.isReady("gigantic"))
        #expect(scratch.storage.folder(for: "../../etc/passwd") == nil)
    }

    @Test("a marker written for one model can't stand in for another")
    func markerMustMatch() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let folder = try scratch.modelFolder("openai_whisper-tiny")
        try scratch.storage.markReady("tiny", folder: folder)
        let markers = scratch.base.appendingPathComponent("ready")
        try FileManager.default.copyItem(at: markers.appendingPathComponent("tiny.json"), to: markers.appendingPathComponent("small.json"))
        #expect(!scratch.storage.isReady("small"))
    }

    @Test("removing a model deletes its files and its marker, and leaves the others alone")
    func remove() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let tiny = try scratch.modelFolder("openai_whisper-tiny")
        let base = try scratch.modelFolder("openai_whisper-base.en")
        try scratch.storage.markReady("tiny", folder: tiny)
        try scratch.storage.markReady("base.en", folder: base)
        try scratch.storage.remove("tiny")
        #expect(!FileManager.default.fileExists(atPath: tiny.path) && !scratch.storage.isReady("tiny"))
        #expect(scratch.storage.isReady("base.en") && FileManager.default.fileExists(atPath: base.path))
        try scratch.storage.remove("tiny")   // removing what isn't there is not an error
    }

    @Test("the real folder is Voxa's own, in Application Support, and not Documents")
    func standardFolder() {
        let path = WhisperStorage.standard.base.path
        #expect(path.hasSuffix("Library/Application Support/Voxa/Models/whisper"))
        #expect(!path.contains("/Documents/"))
    }
}
