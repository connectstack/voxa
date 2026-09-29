import Foundation
import Testing
import VoxaCore
import VoxaLLM
import VoxaPermissions
@testable import VoxaSettings
import VoxaTestSupport

@MainActor
@Suite("Walkthrough")
struct OnboardingModelTests {
    private let fake = FakePermissions()
    private let keys: [ModelProvider: InMemoryAPIKeyStore] = [.anthropic: InMemoryAPIKeyStore(), .openAI: InMemoryAPIKeyStore()]

    private func make(settings: AppSettings = AppSettings()) -> (OnboardingModel, SettingsStore) {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "com.rohitsainier.voxa.tests.onboarding.\(UUID().uuidString)")!)
        store.current = settings
        let permissions = PermissionsModel(permissions: fake, kinds: SettingsServices.listedPermissions)
        let model = OnboardingModel(store: store, permissions: permissions, keys: keys.mapValues { $0 as any APIKeyStoring })
        return (model, store)
    }

    @Test("it walks through four steps in order, and back again, and can't go past either end")
    func steps() {
        let (model, _) = make()
        #expect(model.step == .welcome && model.isFirst && !model.isLast)
        model.back()
        #expect(model.step == .welcome)

        let order: [OnboardingModel.Step] = [.permissions, .model, .ready]
        for expected in order {
            model.advance()
            #expect(model.step == expected)
        }
        #expect(model.isLast)
        model.advance()
        #expect(model.step == .ready)
        model.back()
        #expect(model.step == .model)
    }

    @Test("it can hear only when both the microphone and speech recognition are allowed")
    func canHear() {
        fake.statuses[.microphone] = .granted
        fake.statuses[.speechRecognition] = .notDetermined
        let (model, _) = make()
        #expect(!model.canHear)

        fake.statuses[.speechRecognition] = .granted
        model.permissions.refresh()
        #expect(model.canHear)

        fake.statuses[.microphone] = .denied
        model.permissions.refresh()
        #expect(!model.canHear)
    }

    @Test("a model is set up when the chosen provider has a key, or (for Ollama) a chosen model")
    func hasModel() {
        let (claude, _) = make(settings: AppSettings(provider: .anthropic))
        #expect(!claude.hasModel)
        try? keys[.anthropic]?.save("sk-ant-x")
        #expect(claude.hasModel)

        let (openAI, _) = make(settings: AppSettings(provider: .openAI))
        #expect(!openAI.hasModel, "a Claude key isn't an OpenAI key")
        try? keys[.openAI]?.save("sk-openai-x")
        #expect(openAI.hasModel)

        let (ollamaNone, _) = make(settings: AppSettings(provider: .ollama, ollamaModel: ""))
        #expect(!ollamaNone.hasModel)
        let (ollama, _) = make(settings: AppSettings(provider: .ollama, ollamaModel: "qwen3:8b"))
        #expect(ollama.hasModel)
    }

    @Test("the last step says plainly what is still missing, and says nothing when all is well")
    func warnings() {
        fake.statuses[.microphone] = .denied
        fake.statuses[.speechRecognition] = .granted
        let (model, _) = make(settings: AppSettings(provider: .ollama, ollamaModel: ""))
        #expect(model.warnings == [L10n.Onboarding.missingMicrophone, L10n.Onboarding.missingModel])

        fake.statuses[.microphone] = .granted
        model.permissions.refresh()
        #expect(model.warnings == [L10n.Onboarding.missingModel])

        let (ready, _) = make(settings: AppSettings(provider: .ollama, ollamaModel: "qwen3:8b"))
        #expect(ready.warnings.isEmpty)
    }

    @Test("finishing, or skipping to the end, marks the walkthrough done so it doesn't open by itself again")
    func finish() {
        let (model, store) = make()
        #expect(!store.current.onboardingCompleted)
        model.finish()
        #expect(store.current.onboardingCompleted)
    }

    @Test("it can start at any step, for a preview")
    func startingAt() {
        let store = SettingsStore(defaults: UserDefaults(suiteName: "com.rohitsainier.voxa.tests.onboarding.\(UUID().uuidString)")!)
        let model = OnboardingModel(
            store: store, permissions: PermissionsModel(permissions: fake, kinds: []), keys: [:], startingAt: .model
        )
        #expect(model.step == .model)
    }
}
