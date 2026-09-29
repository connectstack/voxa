import Foundation
import Testing
import VoxaCore
@testable import VoxaSpeech
import VoxaTestSupport

/// A pretend model host: which models are on disk, and installs that wait until the test lets them finish.
private final class FakeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var _installed: Set<String>
    private var _installs: [String] = []
    private var _removed: [String] = []
    var gate: AsyncGate?
    var failure: (any Error)?
    var report: (@Sendable (WhisperModelsModel.Progress) -> Void)?

    init(installed: Set<String> = []) { _installed = installed }

    var installs: [String] { lock.withLock { _installs } }
    var removed: [String] { lock.withLock { _removed } }

    var actions: WhisperModelsModel.Actions {
        WhisperModelsModel.Actions(
            installed: { self.lock.withLock { self._installed } },
            install: { id, progress in
                self.lock.withLock { self._installs.append(id) }
                self.report?(progress)
                await self.gate?.wait()
                try Task.checkCancellation()
                if let failure = self.failure { throw failure }
                self.lock.withLock { _ = self._installed.insert(id) }
            },
            remove: { id in
                self.lock.withLock {
                    self._removed.append(id)
                    self._installed.remove(id)
                }
            }
        )
    }
}

@MainActor
@Suite("WhisperModelsModel")
struct WhisperModelsModelTests {
    /// Waits for the model to reach a state, however busy the machine running the tests is.
    private func waitFor(_ model: WhisperModelsModel, _ id: String, _ state: WhisperModelsModel.State) async -> Bool {
        await waitUntil { model.state(of: id) == state }
    }

    /// Gives work that should NOT happen a moment in which it could, so a test can show it didn't.
    private func settle() async { try? await Task.sleep(for: .milliseconds(60)) }

    @Test("what is on disk shows as ready, and everything else as not downloaded")
    func refresh() async {
        let model = WhisperModelsModel(actions: FakeHost(installed: ["base.en"]).actions)
        await model.refresh()
        #expect(model.state(of: "base.en") == .ready)
        #expect(model.state(of: "small") == .notInstalled)
        #expect(model.hasInstalledModel && !model.isBusy)
    }

    @Test("a download reports its progress, then getting the model ready, then ready")
    func download() async {
        let host = FakeHost()
        let gate = AsyncGate()
        host.gate = gate
        host.report = { progress in
            progress.downloading(0.4)
            progress.preparing()
        }
        let model = WhisperModelsModel(actions: host.actions)
        model.download("base.en")
        #expect(model.state(of: "base.en") == .downloading(fraction: 0) && model.isBusy)
        #expect(await waitFor(model, "base.en", .preparing), "progress arrived, then the preparing step")
        await gate.open()
        #expect(await waitFor(model, "base.en", .ready))
        #expect(!model.isBusy)
        #expect(host.installs == ["base.en"])
    }

    @Test("progress is kept between 0 and 1")
    func progressRange() async {
        let host = FakeHost()
        let gate = AsyncGate()
        host.gate = gate
        host.report = { $0.downloading(1.7) }
        let model = WhisperModelsModel(actions: host.actions)
        model.download("tiny")
        #expect(await waitFor(model, "tiny", .downloading(fraction: 1)))
        await gate.open()
        #expect(await waitFor(model, "tiny", .ready))
    }

    @Test("only one model is fetched at a time, and one that is ready isn't fetched again")
    func oneAtATime() async {
        let host = FakeHost(installed: ["tiny"])
        let gate = AsyncGate()
        host.gate = gate
        let model = WhisperModelsModel(actions: host.actions)
        await model.refresh()
        model.download("base.en")
        model.download("small")  // ignored: another is in progress
        model.download("tiny")  // ignored: already here
        #expect(await waitUntil { host.installs == ["base.en"] })
        await settle()
        #expect(host.installs == ["base.en"], "the other two were never started")
        await gate.open()
        #expect(await waitFor(model, "base.en", .ready))
        #expect(model.state(of: "small") == .notInstalled)
        #expect(host.installs == ["base.en"])
    }

    @Test("a failure is kept, with its reason, until the person tries again, and trying again works")
    func failure() async {
        struct Offline: Error, LocalizedError {
            var errorDescription: String? { "The internet connection appears to be offline." }
        }
        let host = FakeHost()
        host.failure = Offline()
        let model = WhisperModelsModel(actions: host.actions)
        model.download("base.en")
        let offline = WhisperModelsModel.State.failed("The internet connection appears to be offline.")
        #expect(await waitFor(model, "base.en", offline))
        #expect(await waitUntil { !model.isBusy })

        await model.refresh()
        #expect(model.state(of: "base.en") == offline, "a refresh doesn't hide the reason")

        host.failure = nil
        model.download("base.en")
        #expect(await waitFor(model, "base.en", .ready))
    }

    @Test("cancelling a download puts the model back to not downloaded, and frees the next one")
    func cancel() async {
        let host = FakeHost()
        host.gate = AsyncGate()  // held shut: a download that is still going
        let model = WhisperModelsModel(actions: host.actions)
        model.download("small")
        #expect(await waitUntil { host.installs == ["small"] })
        model.cancel("tiny")  // some other model: nothing happens
        await settle()
        #expect(model.isBusy)
        model.cancel("small")
        await host.gate?.open()
        #expect(await waitFor(model, "small", .notInstalled))
        #expect(!model.isBusy)

        model.download("tiny")
        #expect(await waitFor(model, "tiny", .ready), "the next download is free to start")
        #expect(host.installs == ["small", "tiny"])
    }

    @Test("removing a model deletes it, and is not possible while another is being fetched")
    func remove() async {
        let host = FakeHost(installed: ["tiny", "base.en"])
        let gate = AsyncGate()
        let model = WhisperModelsModel(actions: host.actions)
        await model.refresh()
        model.remove("tiny")
        #expect(await waitFor(model, "tiny", .notInstalled))
        #expect(host.removed == ["tiny"])

        host.gate = gate
        model.download("small")
        #expect(await waitUntil { host.installs == ["small"] })
        model.remove("base.en")
        await settle()
        #expect(host.removed == ["tiny"], "not while a download is going")
        await gate.open()
        #expect(await waitFor(model, "small", .ready))
    }

    @Test("a name that isn't in the catalog is never fetched")
    func unknown() async {
        let host = FakeHost()
        let model = WhisperModelsModel(actions: host.actions)
        model.download("large-v3")
        await settle()
        #expect(host.installs.isEmpty && !model.isBusy)
    }

    @Test("the inert one has nothing and does nothing")
    func inert() async {
        let model = WhisperModelsModel.inert
        await model.refresh()
        #expect(!model.hasInstalledModel)
        model.download("tiny")
        #expect(await waitFor(model, "tiny", .ready), "an install that does nothing succeeds at nothing")
    }
}
