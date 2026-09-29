import Foundation
import VoxaAgent
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaLLM
import VoxaPermissions
import VoxaSettings
import VoxaSpeech
import VoxaTools

/// The composition root: builds the concrete services once and wires them together. Nothing else in the app
/// constructs a service, so swapping an implementation (or a fake, in tests) is a change in exactly one place.
@MainActor
public final class AppEnvironment {
    public let settings: SettingsStore
    public let permissions: SystemPermissionsManager
    public let hotkeys: KeyboardShortcutsHotkeyService
    public let hud: HUDController
    public let settingsWindow: SettingsWindowController
    public let session: VoiceSessionController
    public let confirmations: ConfirmationCoordinator
    public let agent: AgentService
    /// Where each provider's API key is kept. Ollama has none.
    public let keyStores: [ModelProvider: any APIKeyStoring]
    public let audit: JSONLAuditLog

    public init(defaults: UserDefaults = .standard) {
        let overrides = DevelopmentOverrides.current
        let settings = SettingsStore(defaults: overrides.settingsDefaults ?? defaults)
        let permissions = SystemPermissionsManager()
        let hotkeys = KeyboardShortcutsHotkeyService()
        let hud = HUDController()

        // Each API key lives in the Keychain. A development build pointed at a local mock server can supply a throwaway key
        // through the environment instead, so testing never touches the real Keychain entries.
        let keyStores: [ModelProvider: any APIKeyStoring] = [
            .anthropic: overrides.apiKey.map { InMemoryAPIKeyStore(key: $0) } ?? KeychainAPIKeyStore(),
            .openAI: overrides.openAIKey.map { InMemoryAPIKeyStore(key: $0) }
                ?? KeychainAPIKeyStore(account: ModelProvider.openAI.keychainAccount ?? "openai-api-key"),
        ]
        let ollamaDiscovery = OllamaDiscovery()
        let llm = RoutingLLMClient(
            anthropic: AnthropicClient(
                keys: keyStores[.anthropic] ?? InMemoryAPIKeyStore(),
                baseURL: overrides.baseURL ?? AnthropicClient.officialBaseURL
            ),
            openAI: OpenAIClient(keys: keyStores[.openAI] ?? InMemoryAPIKeyStore()),
            ollama: OllamaClient(discovery: ollamaDiscovery)
        )
        let audit = overrides.auditLogURL.map { JSONLAuditLog(url: $0) } ?? JSONLAuditLog()

        let confirmations = ConfirmationCoordinator(hud: hud, hotkeys: hotkeys)
        let agent = AgentService(
            llm: llm,
            registry: ToolRegistry(StandardTools.make()),
            confirmations: confirmations,
            audit: audit,
            systemPrompt: Self.loadSystemPrompt(),
            settings: { await settings.current }
        )
        let connectionTest = ProviderConnectionTest(llm: llm, ollama: ollamaDiscovery, settings: { await settings.current })
        let settingsWindow = SettingsWindowController(
            store: settings,
            services: ProviderServices(
                keys: keyStores,
                testConnection: { await connectionTest.run($0) },
                ollama: ollamaDiscovery,
                openOllama: { OllamaLauncher.launch() }
            )
        )

        self.settings = settings
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.hud = hud
        self.settingsWindow = settingsWindow
        self.confirmations = confirmations
        self.agent = agent
        self.keyStores = keyStores
        self.audit = audit
        self.session = VoiceSessionController(
            capture: MicrophoneCapture(),
            recognizers: DefaultSpeechRecognizerProvider(),
            permissions: permissions,
            hud: hud,
            hotkeys: hotkeys,
            settings: settings,
            openAppSettings: { [weak settingsWindow] in settingsWindow?.show() },
            openModelSettings: { [weak settingsWindow] in settingsWindow?.show(tab: .model) },
            agent: agent,
            confirmations: confirmations
        )
    }

    /// Registers the global shortcuts and starts reacting to them. Call once, after launch.
    public func start() {
        hotkeys.start()
        session.start()
        Task { await session.prewarm() }
        #if DEBUG
        installDebugHooks()
        #endif
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

/// Settings for development builds only. Release builds always use the Keychain, Anthropic's own endpoint, the user's own
/// preferences and the standard audit file, whatever the environment says.
struct DevelopmentOverrides {
    var baseURL: URL?
    var apiKey: String?
    var openAIKey: String?
    var auditLogURL: URL?
    /// Keeps settings in a separate preferences domain, so a test run can't change the user's real ones.
    var settingsDefaults: UserDefaults?

    static var current: DevelopmentOverrides {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return DevelopmentOverrides(
            baseURL: environment["VOXA_ANTHROPIC_BASE_URL"].flatMap(URL.init(string:)),
            apiKey: environment["VOXA_DEBUG_API_KEY"],
            openAIKey: environment["VOXA_DEBUG_OPENAI_API_KEY"],
            auditLogURL: environment["VOXA_DEBUG_AUDIT_PATH"].map { URL(fileURLWithPath: $0) },
            settingsDefaults: environment["VOXA_DEBUG_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) }
        )
        #else
        return DevelopmentOverrides()
        #endif
    }
}
