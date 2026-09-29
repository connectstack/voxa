import Foundation
import Testing
import VoxaCore
import VoxaSpeech
import VoxaTestSupport
@testable import VoxaWhisper
@preconcurrency import WhisperKit

@Suite("Waiting for work that can't be cancelled")
struct CancellableWaitTests {
    @Test("the result of the work comes back, and so does its error")
    func result() async throws {
        #expect(try await abandoningOnCancel { 42 } == 42)
        struct Boom: Error, Equatable {}
        await #expect(throws: Boom.self) { try await abandoningOnCancel { throw Boom() } as Int }
    }

    @Test("cancelling the wait returns at once, and the work carries on in the background")
    func cancelled() async throws {
        let gate = AsyncGate()
        let finished = AsyncGate()
        let task = Task {
            try await abandoningOnCancel {
                await gate.wait()
                await finished.open()
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.open()
        await finished.wait()  // the work still ran to the end
    }

    @Test("a wait that is already cancelled never starts the work")
    func alreadyCancelled() async throws {
        let started = Flag()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await abandoningOnCancel { started.set() }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!started.isSet)
    }
}

/// Something the work can set, for a test to look at afterwards.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Suite("AsyncMutex")
struct AsyncMutexTests {
    private actor Counter {
        private(set) var running = 0
        private(set) var mostAtOnce = 0
        func enter() { running += 1; mostAtOnce = max(mostAtOnce, running) }
        func leave() { running -= 1 }
    }

    @Test("two who ask at once go one after the other")
    func serial() async {
        let mutex = AsyncMutex()
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await mutex.lock()
                    await counter.enter()
                    try? await Task.sleep(for: .milliseconds(5))
                    await counter.leave()
                    await mutex.unlock()
                }
            }
        }
        #expect(await counter.mostAtOnce == 1)
    }
}

@Suite("Whisper engine")
struct WhisperEngineTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voxa-whisper-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("decoding is plain and deterministic, and works out the language only when it isn't known")
    func options() {
        let english = WhisperKitTranscriber.options(language: "en")
        #expect(english.language == "en" && !english.detectLanguage && english.temperature == 0)
        #expect(english.skipSpecialTokens && english.withoutTimestamps && !english.wordTimestamps)
        #expect(WhisperKitTranscriber.options(language: nil).detectLanguage)
    }

    @Test("a model that isn't downloaded is never loaded, and nothing is fetched: the error says how to get it")
    func notDownloaded() async {
        let folder = scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = WhisperEngineHost(storage: WhisperStorage(base: folder))
        await #expect(throws: SpeechError.whisperModelMissing(name: "base.en")) {
            _ = try await host.transcriber(forModel: "base.en")
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path), "not even the folder was made")
    }

    @Test("a model whose files are unusable fails in words, and the next try starts afresh")
    func unusableModel() async throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let storage = WhisperStorage(base: base)
        let empty = base.appendingPathComponent("models/openai_whisper-tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try storage.markReady("tiny", folder: empty)

        let host = WhisperEngineHost(storage: storage)
        for _ in 0..<2 {
            do {
                _ = try await host.transcriber(forModel: "tiny")
                Issue.record("an empty folder can't be loaded as a model")
            } catch let error as SpeechError {
                guard case .whisperFailed(let reason) = error else {
                    Issue.record("wrong error \(error)")
                    return
                }
                #expect(!reason.isEmpty)
            }
        }
    }

    @Test("the façade builds a Whisper recognizer for the chosen model and lists what is downloaded")
    func support() async throws {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let support = WhisperSupport(folder: base)
        #expect(support.recognizer(for: AppSettings(speechEngine: .whisper, whisperModel: "small")) is WhisperRecognizer)
        #expect(await support.modelActions.installed().isEmpty)

        let folder = base.appendingPathComponent("models/openai_whisper-tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WhisperStorage(base: base).markReady("tiny", folder: folder)
        #expect(await support.modelActions.installed() == ["tiny"])
        try await support.modelActions.remove("tiny")
        #expect(await support.modelActions.installed().isEmpty)
    }

    @Test("a model Voxa doesn't offer can't be installed, and nothing is touched")
    func unknownInstall() async {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let progress = WhisperModelsModel.Progress(downloading: { _ in }, preparing: {})
        await #expect(throws: SpeechError.self) {
            try await WhisperSupport(folder: base).modelActions.install("large-v3", progress)
        }
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }
}
