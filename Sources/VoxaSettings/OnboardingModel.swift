import Foundation
import Observation
import VoxaCore
import VoxaLLM
import VoxaPermissions

/// Where the first-run walkthrough is, and what it knows about whether Voxa is ready to use. Kept apart from the view so the
/// steps and the readiness rules are tested without a window.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, permissions, model, ready
        var id: Int { rawValue }
    }

    private(set) var step: Step
    let permissions: PermissionsModel

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let keys: [ModelProvider: any APIKeyStoring]
    /// Bumped to make the view read the Keychain again after the key is saved in the embedded form.
    var refreshTick = 0

    init(
        store: SettingsStore,
        permissions: PermissionsModel,
        keys: [ModelProvider: any APIKeyStoring],
        startingAt step: Step = .welcome
    ) {
        self.step = step
        self.store = store
        self.permissions = permissions
        self.keys = keys
    }

    var isFirst: Bool { step == .welcome }
    var isLast: Bool { step == .ready }

    func advance() {
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    // MARK: Readiness

    /// Voxa can't hear anything without these two.
    var canHear: Bool {
        permissions.status(of: .microphone).isGranted && permissions.status(of: .speechRecognition).isGranted
    }

    /// Whether the chosen provider has what it needs: a saved key, or (for Ollama) a chosen model.
    var hasModel: Bool {
        _ = refreshTick
        let settings = store.current
        switch settings.provider {
        case .anthropic, .openAI: return keys[settings.provider]?.hasKey() == true
        case .ollama: return !settings.ollamaModel.isEmpty
        }
    }

    /// What is still missing, for the last step to say plainly.
    var warnings: [String] {
        var warnings: [String] = []
        if !canHear { warnings.append(L10n.Onboarding.missingMicrophone) }
        if !hasModel { warnings.append(L10n.Onboarding.missingModel) }
        return warnings
    }

    /// The walkthrough is done (or was skipped), and won't open by itself again.
    func finish() {
        store.current.onboardingCompleted = true
    }
}
