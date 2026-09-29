import Foundation
import Testing
@testable import VoxaCore

@Suite("AppSettings")
struct AppSettingsTests {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test("an empty object decodes to the defaults")
    func emptyObject() throws {
        let settings = try decode("{}")
        #expect(settings.speechEngine == .appleAutomatic)
        #expect(settings.maxRecordingSeconds == AppSettings.defaultMaxRecordingSeconds)
        #expect(settings.localeIdentifier == AppSettings.systemLocaleIdentifier)
        #expect(settings.downloadSpeechModel)
    }

    @Test("agent settings default sensibly and clamp to safe ranges")
    func agentDefaults() throws {
        let defaults = try decode("{}")
        #expect(defaults.model == "claude-sonnet-5-5")
        #expect(defaults.effort == .medium)
        #expect(defaults.confirmationStrictness == .standard)
        #expect(defaults.disabledTools.isEmpty)
        #expect(defaults.useRefusalFallback)
        #expect(defaults.maxAgentSteps == 12)
        #expect(defaults.followUpWindowSeconds == 120)

        let extreme = try decode(#"{"maxAgentSteps": 9999, "followUpWindowSeconds": -5, "model": "   "}"#)
        #expect(extreme.maxAgentSteps == 25)
        #expect(extreme.followUpWindowSeconds == 0)
        #expect(extreme.model == "claude-sonnet-5-5", "a blank model name falls back to the default")
        #expect(try decode(#"{"maxAgentSteps": 0}"#).maxAgentSteps == 1)
    }

    @Test("settings saved before other providers existed still load, and default to Claude")
    func olderSettingsKeepWorking() throws {
        let saved = try decode(#"{"model":"claude-opus-5-5","effort":"high","localeIdentifier":"en_GB"}"#)
        #expect(saved.provider == .anthropic)
        #expect(saved.model == "claude-opus-5-5")
        #expect(saved.activeModel == "claude-opus-5-5")
        #expect(saved.openAIModel == AppSettings.defaultOpenAIModel)
        #expect(saved.ollamaModel.isEmpty)
        #expect(saved.localeIdentifier == "en_GB")
    }

    @Test("each provider has its own model, and the active one follows the choice")
    func perProviderModels() throws {
        let settings = try decode(#"{"provider":"openAI","model":"claude-sonnet-5-5","openAIModel":"gpt-6-sol","ollamaModel":"qwen3:8b"}"#)
        #expect(settings.provider == .openAI)
        #expect(settings.activeModel == "gpt-6-sol")

        var chosen = settings
        chosen.provider = .ollama
        #expect(chosen.activeModel == "qwen3:8b")
        chosen.provider = .anthropic
        #expect(chosen.activeModel == "claude-sonnet-5-5")
    }

    @Test("provider addresses default sensibly, are trimmed, and a blank one falls back")
    func addresses() throws {
        let defaults = try decode("{}")
        #expect(defaults.openAIBaseURL == "https://api.openai.com/v1")
        #expect(defaults.ollamaBaseURL == "http://localhost:11434")
        #expect(defaults.ollamaContextLength == 16_384)

        let messy = try decode(#"{"openAIBaseURL":"  ","ollamaBaseURL":" http://10.0.0.5:11434 \n","openAIModel":"   "}"#)
        #expect(messy.openAIBaseURL == AppSettings.defaultOpenAIBaseURL)
        #expect(messy.ollamaBaseURL == "http://10.0.0.5:11434")
        #expect(messy.openAIModel == AppSettings.defaultOpenAIModel)
    }

    @Test("only the active provider's address is offered, and Claude uses its own built-in one")
    func activeAddress() {
        var settings = AppSettings()
        #expect(settings.activeBaseURL == nil)
        settings.provider = .openAI
        #expect(settings.activeBaseURL?.absoluteString == "https://api.openai.com/v1")
        settings.provider = .ollama
        #expect(settings.activeBaseURL?.absoluteString == "http://localhost:11434")
    }

    @Test("the Ollama context window is kept within what a model can use")
    func contextLength() throws {
        #expect(try decode(#"{"ollamaContextLength": 1}"#).ollamaContextLength == 2_048)
        #expect(try decode(#"{"ollamaContextLength": 99999999}"#).ollamaContextLength == 131_072)
        #expect(try decode(#"{"ollamaContextLength": 32768}"#).ollamaContextLength == 32_768)
    }

    @Test("an unrecognized provider falls back without discarding the rest")
    func unknownProvider() throws {
        let settings = try decode(#"{"provider":"skynet","openAIModel":"gpt-6-sol"}"#)
        #expect(settings.provider == .anthropic)
        #expect(settings.openAIModel == "gpt-6-sol")
    }

    @Test("providers: which use a key, and where it is kept")
    func providers() {
        #expect(ModelProvider.anthropic.usesAPIKey && ModelProvider.openAI.usesAPIKey)
        #expect(!ModelProvider.ollama.usesAPIKey)
        #expect(ModelProvider.anthropic.keychainAccount == "anthropic-api-key")
        #expect(ModelProvider.openAI.keychainAccount == "openai-api-key")
        #expect(ModelProvider.ollama.keychainAccount == nil)
        #expect(Set(ModelProvider.allCases.map(\.displayName)).count == 3)
    }

    @Test("provider settings survive an encode and decode unchanged")
    func providerSettingsRoundTrip() throws {
        var settings = AppSettings(localeIdentifier: "en_US")
        settings.provider = .ollama
        settings.ollamaModel = "qwen3:8b"
        settings.ollamaBaseURL = "http://192.168.1.20:11434"
        settings.ollamaContextLength = 32_768
        settings.openAIModel = "gpt-6-sol"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
    }

    @Test("unreadable agent values fall back individually")
    func agentTolerance() throws {
        let settings = try decode(#"{"effort":"turbo","confirmationStrictness":"paranoid","disabledTools":["run_applescript"]}"#)
        #expect(settings.effort == .medium)
        #expect(settings.confirmationStrictness == .paranoid)
        #expect(settings.disabledTools == ["run_applescript"])
    }

    @Test("the model-download preference round-trips and tolerates a bad value")
    func downloadPreference() throws {
        #expect(try decode(#"{"downloadSpeechModel":false}"#).downloadSpeechModel == false)
        #expect(try decode(#"{"downloadSpeechModel":"maybe"}"#).downloadSpeechModel == true)
    }

    @Test("an unrecognized enum value falls back without discarding the other settings")
    func unknownEngine() throws {
        let settings = try decode(#"{"speechEngine":"telepathy","localeIdentifier":"fr_FR"}"#)
        #expect(settings.speechEngine == .appleAutomatic)
        #expect(settings.localeIdentifier == "fr_FR")
    }

    @Test("unknown keys from a newer version are ignored")
    func unknownKeys() throws {
        let settings = try decode(#"{"localeIdentifier":"de_DE","someFutureSetting":true}"#)
        #expect(settings.localeIdentifier == "de_DE")
    }

    @Test("the recording limit is clamped to a sane range", arguments: [(-5, 5), (0, 5), (30, 30), (999, 300)])
    func clamping(input: Int, expected: Int) throws {
        #expect(try decode(#"{"maxRecordingSeconds":\#(input)}"#).maxRecordingSeconds == expected)
    }

    @Test("encoding then decoding is lossless")
    func roundTrip() throws {
        let original = AppSettings(
            speechEngine: .appleClassic,
            localeIdentifier: "en_IN",
            maxRecordingSeconds: 45,
            downloadSpeechModel: false
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == original)
    }

    @Test("the system locale identifier is a plain language_REGION without extensions")
    func systemLocale() {
        let identifier = AppSettings.systemLocaleIdentifier
        #expect(!identifier.contains("@"))
        #expect(!identifier.isEmpty)
    }
}
