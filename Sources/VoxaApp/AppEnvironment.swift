import Foundation
import VoxaAgent
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaLLM
import VoxaPermissions
import VoxaPolicy
import VoxaSettings
import VoxaSpeech
import VoxaTools
import VoxaVoice
import VoxaWhisper

/// The composition root: builds the concrete services once and wires them together. Nothing else in the app
/// constructs a service, so swapping an implementation (or a fake, in tests) is a change in exactly one place.
@MainActor
public final class AppEnvironment {
    public let settings: SettingsStore
    public let permissions: SystemPermissionsManager
    public let hotkeys: KeyboardShortcutsHotkeyService
    public let hud: HUDController
    public let settingsWindow: SettingsWindowController
    public let onboardingWindow: OnboardingWindowController
    public let session: VoiceSessionController
    public let confirmations: ConfirmationCoordinator
    public let agent: AgentService
    /// Where each provider's API key is kept. Ollama has none.
    public let keyStores: [ModelProvider: any APIKeyStoring]
    public let audit: JSONLAuditLog
    public let speaker: ReplySpeaker
    /// What the settings screens are given. Kept so Debug builds can press the same buttons those screens do.
    let settingsServices: SettingsServices
    private let frontmost: SystemFrontmostContext

    // The composition root: it builds each service once and wires them together, so its length is the wiring itself.
    // swiftlint:disable:next function_body_length
    public init(defaults: UserDefaults = .standard) {
        let overrides = DevelopmentOverrides.current
        let settings = SettingsStore(defaults: overrides.settingsDefaults ?? defaults)
        let permissions = SystemPermissionsManager()
        let hotkeys = KeyboardShortcutsHotkeyService()
        let hud = HUDController()

        let keyStores = Self.makeKeyStores(overrides)
        let ollamaDiscovery = OllamaDiscovery()
        let llm = Self.makeClient(keyStores: keyStores, overrides: overrides, ollama: ollamaDiscovery)
        let audit = overrides.auditLogURL.map { JSONLAuditLog(url: $0) } ?? JSONLAuditLog()

        // What Voxa says aloud, and what the tools reach into.
        let speaker = ReplySpeaker(synthesizer: AVFoundationSpeaker(), settings: settings)
        let frontmost = SystemFrontmostContext()
        let tools = StandardTools.make(system: Self.makeSystemAccess(overrides, frontmost: frontmost))

        // The permission gate for tools, and what Settings shows: the real answers, unless a development run scripts some.
        let toolPermissions: any PermissionsProviding =
            overrides.permissionStatuses.isEmpty ? permissions : ScriptedPermissions(overrides.permissionStatuses, real: permissions)
        let permissionsModel = PermissionsModel(permissions: toolPermissions, kinds: SettingsServices.listedPermissions)

        // Whisper is downloaded only when the person asks in Settings; until then choosing it falls back to Apple's recognizer.
        let whisper = WhisperSupport()
        let whisperModels = WhisperModelsModel(actions: whisper.modelActions)

        let confirmations = ConfirmationCoordinator(hud: hud, hotkeys: hotkeys, speaker: speaker)
        let agent = AgentService(
            llm: llm,
            registry: ToolRegistry(tools),
            confirmations: confirmations,
            permissions: SystemToolPermissions(permissions: toolPermissions),
            audit: audit,
            systemPrompt: Self.loadSystemPrompt(),
            settings: { await settings.current }
        )

        let connectionTest = ProviderConnectionTest(llm: llm, ollama: ollamaDiscovery, settings: { await settings.current })
        let welcome = WelcomeLauncher()
        let services = SettingsServices(
            keys: keyStores,
            testConnection: { await connectionTest.run($0) },
            ollama: ollamaDiscovery,
            openOllama: { OllamaLauncher.launch() },
            permissions: permissionsModel,
            voice: VoiceServices(voices: { speaker.voices() }, speakSample: { speaker.speakSample() }),
            whisper: whisperModels,
            tools: Self.toolInfos(tools),
            audit: audit,
            launchAtLogin: SystemLaunchAtLogin(),
            showWelcome: { welcome.show() }
        )
        let settingsWindow = SettingsWindowController(store: settings, services: services)
        let onboardingWindow = OnboardingWindowController(store: settings, services: services)
        welcome.open = { [weak onboardingWindow] in onboardingWindow?.show() }

        self.settings = settings
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.hud = hud
        self.settingsWindow = settingsWindow
        self.onboardingWindow = onboardingWindow
        self.confirmations = confirmations
        self.agent = agent
        self.keyStores = keyStores
        self.audit = audit
        self.speaker = speaker
        self.settingsServices = services
        self.frontmost = frontmost
        self.session = VoiceSessionController(
            capture: MicrophoneCapture(),
            recognizers: DefaultSpeechRecognizerProvider(whisper: { whisper.recognizer(for: $0) }),
            permissions: permissions,
            hud: hud,
            hotkeys: hotkeys,
            settings: settings,
            openAppSettings: { [weak settingsWindow] in settingsWindow?.show() },
            openModelSettings: { [weak settingsWindow] in settingsWindow?.show(tab: .model) },
            agent: agent,
            confirmations: confirmations,
            speaker: speaker
        )
    }

    /// Registers the global shortcuts and starts reacting to them. Call once, after launch.
    public func start() {
        hotkeys.start()
        session.start()
        frontmost.start()
        Task { await session.prewarm() }
        onboardingWindow.showIfNeeded()
        #if DEBUG
        installDebugHooks()
        #endif
    }

    /// Each API key lives in the Keychain. A development build pointed at a local mock server can supply a throwaway key through
    /// the environment instead, so testing never touches the real Keychain entries.
    private static func makeKeyStores(_ overrides: DevelopmentOverrides) -> [ModelProvider: any APIKeyStoring] {
        [
            .anthropic: overrides.apiKey.map { InMemoryAPIKeyStore(key: $0) } ?? KeychainAPIKeyStore(),
            .openAI: overrides.openAIKey.map { InMemoryAPIKeyStore(key: $0) }
                ?? KeychainAPIKeyStore(account: ModelProvider.openAI.keychainAccount ?? "openai-api-key"),
        ]
    }

    /// One client for all three providers, which sends each request to the one it names.
    private static func makeClient(
        keyStores: [ModelProvider: any APIKeyStoring],
        overrides: DevelopmentOverrides,
        ollama: OllamaDiscovery
    ) -> RoutingLLMClient {
        RoutingLLMClient(
            anthropic: AnthropicClient(
                keys: keyStores[.anthropic] ?? InMemoryAPIKeyStore(),
                baseURL: overrides.baseURL ?? AnthropicClient.officialBaseURL
            ),
            openAI: OpenAIClient(keys: keyStores[.openAI] ?? InMemoryAPIKeyStore()),
            ollama: OllamaClient(discovery: ollama)
        )
    }

    /// The real calendar, reminders, clipboard, windows, screen and files, or, in a development run, made-up sample data that
    /// nobody's real anything is touched by.
    private static func makeSystemAccess(_ overrides: DevelopmentOverrides, frontmost: SystemFrontmostContext) -> SystemAccess {
        if let sample = overrides.sampleData { return .sample(hostile: sample == .hostile) }
        return .real(frontmost: frontmost)
    }

    /// What the Tools tab shows for each tool: its name and description, and how the policy will treat it at the least.
    private static func toolInfos(_ tools: [any AgentTool]) -> [ToolInfo] {
        tools.map { tool in
            ToolInfo(
                name: tool.name,
                summary: tool.summary,
                risk: max(tool.baselineRisk, PolicyFloors.floor(for: tool.name)),
                permissions: tool.requiredPermissions.sorted { $0.rawValue < $1.rawValue }
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// The bundled prompt. A missing resource is a packaging bug; the app still starts, with a bare-bones prompt, and says so
    /// in the log rather than crashing at launch.
    private static func loadSystemPrompt() -> SystemPrompt {
        do {
            return try SystemPrompt()
        } catch {
            Log.app.fault("the system prompt resource is missing; using a minimal fallback")
            return .minimal
        }
    }
}

/// Lets the Settings window open the walkthrough, which is built after it and needs the same services.
@MainActor
private final class WelcomeLauncher {
    var open: (@MainActor () -> Void)?

    func show() { open?() }
}

/// Settings for development builds only. Release builds always use the Keychain, Anthropic's own endpoint, the user's own
/// preferences and the standard audit file, whatever the environment says.
struct DevelopmentOverrides {
    var baseURL: URL?
    var apiKey: String?
    var openAIKey: String?
    var auditLogURL: URL?
    /// Keeps settings in a separate preferences domain, so a test run can't change the user's real ones.
    var settingsDefaults: UserDefaults?
    /// Runs the calendar, reminders, clipboard, window, screenshot and file tools against made-up data instead of the real thing.
    var sampleData: SampleData?

    enum SampleData { case plain, hostile }
    /// Made-up permission answers for tools (`calendars=denied,reminders=notDetermined`), to see what a refusal looks like.
    var permissionStatuses: [PermissionKind: PermissionStatus] = [:]

    static var current: DevelopmentOverrides {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return DevelopmentOverrides(
            baseURL: environment["VOXA_ANTHROPIC_BASE_URL"].flatMap(URL.init(string:)),
            apiKey: environment["VOXA_DEBUG_API_KEY"],
            openAIKey: environment["VOXA_DEBUG_OPENAI_API_KEY"],
            auditLogURL: environment["VOXA_DEBUG_AUDIT_PATH"].map { URL(fileURLWithPath: $0) },
            settingsDefaults: environment["VOXA_DEBUG_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) },
            sampleData: environment["VOXA_DEBUG_SAMPLE_DATA"].flatMap { $0 == "hostile" ? SampleData.hostile : ($0 == "1" ? .plain : nil) },
            permissionStatuses: parseStatuses(environment["VOXA_DEBUG_TOOL_PERMISSIONS"])
        )
        #else
        return DevelopmentOverrides()
        #endif
    }
}

#if DEBUG
/// `calendars=denied,reminders=notDetermined` as permission statuses.
private func parseStatuses(_ text: String?) -> [PermissionKind: PermissionStatus] {
    var result: [PermissionKind: PermissionStatus] = [:]
    for pair in (text ?? "").split(separator: ",") {
        let parts = pair.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let kind = PermissionKind(rawValue: parts[0]) else { continue }
        switch parts[1] {
        case "granted": result[kind] = .granted
        case "denied": result[kind] = .denied
        case "restricted": result[kind] = .restricted
        case "notDetermined": result[kind] = .notDetermined
        default: continue
        }
    }
    return result
}
#endif
