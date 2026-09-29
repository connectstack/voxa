import Foundation
import Observation
import VoxaCore

/// What the buttons in Settings drive: which Whisper models are on this Mac, which one is being fetched, and what became of it.
///
/// Nothing is fetched unless a person presses Download, and only one model is fetched at a time. The work itself (talking to the
/// model host, preparing the model for this Mac's chip) is done by whoever supplies the `Actions`, so this can be tested, and
/// shown in Settings, without the Whisper library.
@MainActor
@Observable
public final class WhisperModelsModel {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// How much has arrived, from 0 to 1.
        case downloading(fraction: Double)
        /// Downloaded, and being compiled for this Mac's chip, which the first time takes a little while.
        case preparing
        case ready
        case failed(String)
    }

    /// What an install reports as it goes.
    public struct Progress: Sendable {
        public var downloading: @Sendable (Double) -> Void
        public var preparing: @Sendable () -> Void

        public init(downloading: @escaping @Sendable (Double) -> Void, preparing: @escaping @Sendable () -> Void) {
            self.downloading = downloading
            self.preparing = preparing
        }
    }

    public struct Actions: Sendable {
        /// The ids of the models that are downloaded and ready.
        public var installed: @Sendable () async -> Set<String>
        public var install: @Sendable (_ id: String, _ progress: Progress) async throws -> Void
        public var remove: @Sendable (_ id: String) async throws -> Void

        public init(
            installed: @escaping @Sendable () async -> Set<String>,
            install: @escaping @Sendable (String, Progress) async throws -> Void,
            remove: @escaping @Sendable (String) async throws -> Void
        ) {
            self.installed = installed
            self.install = install
            self.remove = remove
        }
    }

    public private(set) var states: [String: State] = [:]

    @ObservationIgnored private let actions: Actions
    @ObservationIgnored private var installTask: (id: String, task: Task<Void, Never>)?

    public init(actions: Actions) {
        self.actions = actions
    }

    /// Nothing behind it: no model is on this Mac, and a download does nothing. For previews and tests of the screens.
    public static var inert: WhisperModelsModel {
        WhisperModelsModel(actions: Actions(installed: { [] }, install: { _, _ in }, remove: { _ in }))
    }

    /// A list frozen in the given states, for pictures of the Settings screen. Its buttons do nothing.
    public static func preview(_ states: [String: State]) -> WhisperModelsModel {
        let model = WhisperModelsModel.inert
        model.states = states
        return model
    }

    public func state(of id: String) -> State {
        states[id] ?? .notInstalled
    }

    /// Whether a model is being downloaded or prepared right now.
    public var isBusy: Bool { installTask != nil }

    public var hasInstalledModel: Bool { states.values.contains(.ready) }

    // MARK: Reading what is on disk

    /// Looks at what is downloaded. A model that is being fetched right now keeps its progress.
    public func refresh() async {
        let installed = await actions.installed()
        for model in WhisperModelCatalog.all {
            if let (id, _) = installTask, id == model.id { continue }
            if installed.contains(model.id) {
                states[model.id] = .ready
            } else if case .failed = state(of: model.id) {
                continue   // the reason stays up until the person tries again
            } else {
                states[model.id] = .notInstalled
            }
        }
    }

    // MARK: Changing it

    /// Starts downloading a model. Ignored while another is being fetched.
    public func download(_ id: String) {
        guard installTask == nil, WhisperModelCatalog.model(id) != nil else { return }
        switch state(of: id) {
        case .notInstalled, .failed: break
        default: return
        }
        states[id] = .downloading(fraction: 0)
        let progress = Progress(
            downloading: { [weak self] fraction in
                Task { @MainActor in self?.setDownloading(id, fraction: fraction) }
            },
            preparing: { [weak self] in
                Task { @MainActor in self?.setPreparing(id) }
            }
        )
        let actions = actions
        let task = Task { @MainActor [weak self] in
            do {
                try await actions.install(id, progress)
                self?.finished(id, .ready)
            } catch is CancellationError {
                self?.finished(id, .notInstalled)
            } catch {
                self?.finished(id, .failed(error.localizedDescription))
            }
        }
        installTask = (id, task)
    }

    /// Stops a download that is under way. What had arrived is kept, so the next attempt carries on from there.
    public func cancel(_ id: String) {
        guard let (current, task) = installTask, current == id else { return }
        task.cancel()
    }

    public func remove(_ id: String) {
        guard installTask == nil else { return }
        let actions = actions
        Task { @MainActor [weak self] in
            do {
                try await actions.remove(id)
                self?.states[id] = .notInstalled
            } catch {
                self?.states[id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Progress from the work

    private func setDownloading(_ id: String, fraction: Double) {
        guard case .downloading = state(of: id) else { return }
        states[id] = .downloading(fraction: min(max(fraction, 0), 1))
    }

    private func setPreparing(_ id: String) {
        switch state(of: id) {
        case .downloading, .preparing: states[id] = .preparing
        default: break
        }
    }

    private func finished(_ id: String, _ state: State) {
        states[id] = state
        installTask = nil
    }
}
