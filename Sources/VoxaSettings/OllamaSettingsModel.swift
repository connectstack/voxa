import Foundation
import Observation
import VoxaCore
import VoxaLLM

/// What the Ollama part of Settings knows about the server: whether it is running, which models it has, and what the chosen
/// one can do. Kept apart from the view so it can be tested with a scripted server.
@MainActor
@Observable
final class OllamaSettingsModel {
    enum Status: Equatable {
        case checking
        case running(version: String)
        case notRunning
        /// The address is unusable, or the server said something unexpected.
        case problem(String)
    }

    private(set) var status = Status.checking
    private(set) var models: [OllamaModel] = []
    /// What the chosen model can do; nil until known, or when it can't be found out.
    private(set) var details: OllamaModelDetails?

    @ObservationIgnored private let discovery: any OllamaDiscovering
    /// Bumped by every refresh, so a slow answer for an address the user has already changed is ignored.
    @ObservationIgnored private var generation = 0

    init(discovery: any OllamaDiscovering) {
        self.discovery = discovery
    }

    var isRunning: Bool {
        if case .running = status { true } else { false }
    }

    /// The chosen model, if the server has it.
    func installed(_ name: String) -> OllamaModel? {
        models.first { $0.name == name }
    }

    /// Asks the server what it has and, if a model is chosen, what that model can do.
    func refresh(address: String, chosen: String) async {
        generation += 1
        let mine = generation
        status = .checking

        guard let url = OllamaClient.address(from: address) else {
            models = []
            details = nil
            status = .problem(L10n.SettingsProvider.ollamaBadAddress)
            return
        }

        do {
            let version = try await discovery.version(at: url)
            let installed = try await discovery.models(at: url)
            guard mine == generation else { return }
            models = installed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            status = .running(version: version)
        } catch {
            guard mine == generation else { return }
            models = []
            details = nil
            status = Self.status(for: error)
            return
        }
        await loadDetails(of: chosen, address: address, generation: mine)
    }

    /// Finds out what one model can do (for example that it can't use tools).
    func loadDetails(of model: String, address: String) async {
        await loadDetails(of: model, address: address, generation: generation)
    }

    private func loadDetails(of model: String, address: String, generation mine: Int) async {
        guard !model.isEmpty, installed(model) != nil, let url = OllamaClient.address(from: address) else {
            details = nil
            return
        }
        let found = try? await discovery.details(of: model, at: url)
        guard mine == generation else { return }
        details = found
    }

    // MARK: Helpers

    private static func status(for error: any Error) -> Status {
        guard let failure = error as? LLMError else { return .problem(UserFacingError.describing(error).title) }
        switch failure {
        case .unreachable, .network, .offline:
            return .notRunning
        default:
            return .problem(UserFacingError.describing(ProviderFailure(provider: .ollama, error: failure)).title)
        }
    }
}
