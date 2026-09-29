import Foundation

/// Which speech-to-text engine turns microphone audio into a transcript. All engines run on this Mac.
public enum SpeechEngineKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Newest Apple engine (`SpeechAnalyzer`, macOS 26+) when its model is installed, otherwise the classic recognizer.
    case appleAutomatic
    /// `SFSpeechRecognizer`, forced to on-device recognition.
    case appleClassic

    public var id: String { rawValue }
}

/// How much thinking the model does before answering. Lower is faster, which matters for a voice interface; the API also
/// offers deeper levels, which are too slow for push-to-talk.
public enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case low
    case medium
    case high

    public var id: String { rawValue }
}

/// User-configurable settings that services need to read. Persisted by `SettingsStore` (VoxaSettings).
///
/// Decoding is deliberately forgiving: a missing or unrecognized key falls back to its default instead of failing,
/// so adding a setting in a later release (or downgrading) never wipes the user's other preferences.
public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultMaxRecordingSeconds = 60
    public static let defaultModel = "claude-sonnet-5-5"
    /// OpenAI's efficient model: quick and inexpensive, which suits a voice interface. Any model ID can be typed instead.
    public static let defaultOpenAIModel = "gpt-6-luna"
    public static let defaultOpenAIBaseURL = "https://api.openai.com/v1"
    public static let defaultOllamaBaseURL = "http://localhost:11434"
    /// Ollama's default context window is small enough to silently cut off Voxa's prompt and tools, so requests set it.
    public static let defaultOllamaContextLength = 16_384

    /// The user's language and region as a plain `language_REGION` identifier (e.g. `en_IN`), without the calendar
    /// and region-override extensions that `Locale.current.identifier` can carry and speech engines reject.
    public static var systemLocaleIdentifier: String {
        let current = Locale.current
        guard let language = current.language.languageCode?.identifier else { return "en_US" }
        if let region = current.region?.identifier { return "\(language)_\(region)" }
        return language
    }

    // MARK: Speech

    public var speechEngine: SpeechEngineKind
    /// ICU identifier such as `en_US`; resolved with `Locale(identifier:)`.
    public var localeIdentifier: String
    /// Hard stop for a single push-to-talk recording.
    public var maxRecordingSeconds: Int
    /// Whether the automatic speech engine may download Apple's newer on-device model in the background. Until it has
    /// finished (or if this is off) the classic on-device recognizer is used.
    public var downloadSpeechModel: Bool

    // MARK: Agent

    /// Which service plans and calls tools.
    public var provider: ModelProvider
    /// The Claude model, used when `provider` is `.anthropic`. (The name predates the other providers.)
    public var model: String
    /// The OpenAI model, used when `provider` is `.openAI`.
    public var openAIModel: String
    /// The OpenAI API address. Changing it points Voxa at another server that speaks the same API.
    public var openAIBaseURL: String
    /// The Ollama model, used when `provider` is `.ollama`. Empty until one is chosen.
    public var ollamaModel: String
    public var ollamaBaseURL: String
    /// The context window Voxa asks Ollama for, in tokens.
    public var ollamaContextLength: Int
    public var effort: ReasoningEffort
    /// Let the API re-run a declined request on another model (Anthropic's server-side refusal fallback).
    public var useRefusalFallback: Bool
    /// Hard cap on tool steps per command.
    public var maxAgentSteps: Int
    /// How long after a command a follow-up ("also make it three hours") still refers to it.
    public var followUpWindowSeconds: Int

    // MARK: Safety

    public var confirmationStrictness: ConfirmationStrictness
    /// Names of tools the user has switched off. They are hidden from the model and refused if called anyway.
    public var disabledTools: Set<String>

    public init(
        speechEngine: SpeechEngineKind = .appleAutomatic,
        localeIdentifier: String = AppSettings.systemLocaleIdentifier,
        maxRecordingSeconds: Int = AppSettings.defaultMaxRecordingSeconds,
        downloadSpeechModel: Bool = true,
        provider: ModelProvider = .anthropic,
        model: String = AppSettings.defaultModel,
        openAIModel: String = AppSettings.defaultOpenAIModel,
        openAIBaseURL: String = AppSettings.defaultOpenAIBaseURL,
        ollamaModel: String = "",
        ollamaBaseURL: String = AppSettings.defaultOllamaBaseURL,
        ollamaContextLength: Int = AppSettings.defaultOllamaContextLength,
        effort: ReasoningEffort = .medium,
        useRefusalFallback: Bool = true,
        maxAgentSteps: Int = 12,
        followUpWindowSeconds: Int = 120,
        confirmationStrictness: ConfirmationStrictness = .standard,
        disabledTools: Set<String> = []
    ) {
        self.speechEngine = speechEngine
        self.localeIdentifier = localeIdentifier
        self.maxRecordingSeconds = maxRecordingSeconds
        self.downloadSpeechModel = downloadSpeechModel
        self.provider = provider
        self.model = model
        self.openAIModel = openAIModel
        self.openAIBaseURL = openAIBaseURL
        self.ollamaModel = ollamaModel
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaContextLength = ollamaContextLength
        self.effort = effort
        self.useRefusalFallback = useRefusalFallback
        self.maxAgentSteps = maxAgentSteps
        self.followUpWindowSeconds = followUpWindowSeconds
        self.confirmationStrictness = confirmationStrictness
        self.disabledTools = disabledTools
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    private enum CodingKeys: String, CodingKey {
        case speechEngine, localeIdentifier, maxRecordingSeconds, downloadSpeechModel
        case provider, model, openAIModel, openAIBaseURL, ollamaModel, ollamaBaseURL, ollamaContextLength
        case effort, useRefusalFallback, maxAgentSteps, followUpWindowSeconds
        case confirmationStrictness, disabledTools
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()

        /// A missing or unreadable value falls back to its default instead of failing the whole decode.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        speechEngine = value(.speechEngine, defaults.speechEngine)
        localeIdentifier = value(.localeIdentifier, defaults.localeIdentifier)
        maxRecordingSeconds = min(max(value(.maxRecordingSeconds, defaults.maxRecordingSeconds), 5), 300)
        downloadSpeechModel = value(.downloadSpeechModel, defaults.downloadSpeechModel)

        provider = value(.provider, defaults.provider)
        func text(_ key: CodingKeys, _ fallback: String, allowEmpty: Bool = false) -> String {
            let stored = value(key, fallback).trimmingCharacters(in: .whitespacesAndNewlines)
            return stored.isEmpty && !allowEmpty ? fallback : stored
        }
        model = text(.model, defaults.model)
        openAIModel = text(.openAIModel, defaults.openAIModel)
        openAIBaseURL = text(.openAIBaseURL, defaults.openAIBaseURL)
        ollamaModel = text(.ollamaModel, defaults.ollamaModel, allowEmpty: true)
        ollamaBaseURL = text(.ollamaBaseURL, defaults.ollamaBaseURL)
        ollamaContextLength = min(max(value(.ollamaContextLength, defaults.ollamaContextLength), 2_048), 131_072)
        effort = value(.effort, defaults.effort)
        useRefusalFallback = value(.useRefusalFallback, defaults.useRefusalFallback)
        maxAgentSteps = min(max(value(.maxAgentSteps, defaults.maxAgentSteps), 1), 25)
        followUpWindowSeconds = min(max(value(.followUpWindowSeconds, defaults.followUpWindowSeconds), 0), 600)

        confirmationStrictness = value(.confirmationStrictness, defaults.confirmationStrictness)
        disabledTools = value(.disabledTools, defaults.disabledTools)
    }
}

/// Read access to the current settings. `@MainActor` because the backing store drives SwiftUI; background work
/// receives a value-type snapshot instead of holding the store.
@MainActor
public protocol SettingsProviding: AnyObject {
    var current: AppSettings { get }
}

extension AppSettings {
    /// The model for the chosen provider. Empty when Ollama has no model chosen yet.
    public var activeModel: String {
        switch provider {
        case .anthropic: model
        case .openAI: openAIModel
        case .ollama: ollamaModel
        }
    }

    /// The address to use instead of the provider's built-in one, if the settings name one.
    public var activeBaseURL: URL? {
        switch provider {
        case .anthropic: nil
        case .openAI: URL(string: openAIBaseURL)
        case .ollama: URL(string: ollamaBaseURL)
        }
    }
}
