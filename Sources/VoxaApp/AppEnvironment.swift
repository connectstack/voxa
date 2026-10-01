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

/// The composition root: builds the concrete services once and wires them together. Nothing else in the app
/// constructs a service, so swapping an implementation (or a fake, in tests) is a change in exactly one place.
@MainActor
public final class AppEnvironment {
    public let settings: SettingsStore
    public let permissions: SystemPermissionsManager
    public let hotkeys: KeyboardShortcutsHotkeyService
    /// How Siri is set up (it does the listening: "Hey Siri, ask Voxa"), and the way to its settings.
    public let siri: any SiriInspecting
    public let settingsWindow: SettingsWindowController
    public let onboardingWindow: OnboardingWindowController
    public let session: VoiceSessionController
    /// The Voxa bar: a field to type a command in, the microphone button, and everything Voxa shows while it works.
    public let bar: CommandBarController
    public let confirmations: ConfirmationCoordinator
    public let agent: AgentService
    /// Where each provider's API key is kept. Ollama has none.
    public let keyStores: [ModelProvider: any APIKeyStoring]
    public let audit: JSONLAuditLog
    public let speaker: ReplySpeaker
    /// The running app's environment, for App Intents: the system creates those, in this process, and they have to find Voxa.
    public private(set) static weak var current: AppEnvironment?

    /// What the settings screens are given. Kept so Debug builds can press the same buttons those screens do.
    let settingsServices: SettingsServices
    private let frontmost: SystemFrontmostContext
    private var openBarTask: Task<Void, Never>?

    // The composition root: it builds each service once and wires them together, so its length is the wiring itself.
    // swiftlint:disable:next function_body_length
    public init(defaults: UserDefaults = .standard, keyboard: (any KeyboardActivating)? = nil) {
        let overrides = DevelopmentOverrides.current
        let settings = SettingsStore(defaults: overrides.settingsDefaults ?? defaults)
        let permissions = SystemPermissionsManager()
        let hotkeys = KeyboardShortcutsHotkeyService()
        // The one place Voxa shows itself: a field to type in and a microphone, and what a command is doing below them.
        let bar = CommandBarController(activation: keyboard)

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

        let confirmations = ConfirmationCoordinator(hud: bar, hotkeys: hotkeys, speaker: speaker)
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
        let siri = SystemSiri()
        let services = SettingsServices(
            keys: keyStores,
            testConnection: { await connectionTest.run($0) },
            ollama: ollamaDiscovery,
            openOllama: { OllamaLauncher.launch() },
            permissions: permissionsModel,
            voice: VoiceServices(voices: { speaker.voices() }, speakSample: { speaker.speakSample() }),
            tools: Self.toolInfos(tools),
            audit: audit,
            launchAtLogin: SystemLaunchAtLogin(),
            siri: siri,
            showWelcome: { welcome.show() }
        )
        let settingsWindow = SettingsWindowController(store: settings, services: services)
        let onboardingWindow = OnboardingWindowController(store: settings, services: services)
        welcome.open = { [weak onboardingWindow] in onboardingWindow?.show() }

        self.settings = settings
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.siri = siri
        self.settingsWindow = settingsWindow
        self.onboardingWindow = onboardingWindow
        self.confirmations = confirmations
        self.agent = agent
        self.keyStores = keyStores
        self.audit = audit
        self.speaker = speaker
        self.settingsServices = services
        self.frontmost = frontmost
        // The session opens the microphone for a held key and for the bar's microphone button alike. A development run can play a file
        // into it instead of a microphone, and script what the recognizer hears.
        let session = VoiceSessionController(
            capture: Self.makeCapture(overrides),
            recognizers: Self.makeRecognizers(overrides),
            permissions: Self.sessionPermissions(overrides, real: permissions),
            hud: bar,
            hotkeys: hotkeys,
            settings: settings,
            openAppSettings: { [weak settingsWindow] in settingsWindow?.show() },
            openModelSettings: { [weak settingsWindow] in settingsWindow?.show(tab: .model) },
            agent: agent,
            confirmations: confirmations,
            speaker: speaker
        )
        // The Voxa bar: typing goes to the session, and so does a click on the microphone button, which is a key press and a key
        // release made with the mouse. The bar shows what the session does as it does it, and stays where it can be seen while the
        // button has the microphone open.
        bar.model.onSubmit = { [weak session] command in
            Log.session.info("a command was typed in the bar (\(command.count) characters)")
            return session?.submitCommand(command) ?? false
        }
        bar.model.onMicrophone = { [weak session] in session?.microphoneClicked() }
        bar.model.warning = { [weak settings] in settings?.current.fullControl == true ? L10n.Bar.fullControlWarning : nil }
        bar.keepsOpen = { [weak session] in session?.isMicrophoneOpen ?? false }
        self.session = session
        self.bar = bar
        // Esc, and putting the bar away, let go of the microphone the button opened; that needs the finished environment.
        bar.model.onClose = { [weak self] in self?.closeBar() }
        // A command may type in the app in front, so the bar lets go of the keyboard the moment one starts.
        session.onCommandStarted = { [weak bar] in bar?.releaseKeyboard() }
        Self.current = self
    }

    // MARK: The Voxa bar

    /// Opens the bar, ready for typing.
    public func showBar() {
        bar.open()
    }

    /// Puts the bar away, and lets go of the microphone its button opened: a bar that is gone must not leave a microphone open.
    public func closeBar() {
        session.cancelMicrophone()
        bar.close()
    }

    /// The shortcut: opens the bar, or closes it if it already has the keyboard. While a command is under way there is nothing to type
    /// into, and the bar says so.
    public func toggleBar() {
        if bar.isVisible && bar.hasKeyboard { closeBar() } else { showBar() }
    }

    /// Registers the global shortcuts and starts reacting to them. Call once, after launch.
    public func start() {
        hotkeys.start()
        session.start()
        let opens = hotkeys.openBarPresses
        openBarTask = Task { [weak self] in
            for await _ in opens { self?.toggleBar() }
        }
        frontmost.start()
        Task { await session.prewarm() }
        onboardingWindow.showIfNeeded()
        #if DEBUG
        installDebugHooks()
        #endif
    }

    /// The microphone. A development run can play a file into it instead.
    private static func makeCapture(_ overrides: DevelopmentOverrides) -> any AudioCapturing {
        #if DEBUG
        if let url = overrides.micAudio { return DebugFileMicrophone(url: url) }
        #endif
        return MicrophoneCapture()
    }

    /// Whose answers decide whether the session may listen: the real ones, except that a development run playing a file in place of the
    /// microphone has no microphone to be allowed to use.
    private static func sessionPermissions(
        _ overrides: DevelopmentOverrides,
        real: SystemPermissionsManager
    ) -> any PermissionsProviding {
        #if DEBUG
        if overrides.micAudio != nil {
            return ScriptedPermissions([.microphone: .granted, .speechRecognition: .granted], real: real)
        }
        #endif
        return real
    }

    /// The speech engines Apple provides, all on this Mac. A development run can script what they hear.
    private static func makeRecognizers(_ overrides: DevelopmentOverrides) -> any SpeechRecognizerProviding {
        #if DEBUG
        if let texts = overrides.micTranscripts { return DebugScriptedTranscripts(texts) }
        #endif
        return DefaultSpeechRecognizerProvider()
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
    /// A file the microphone hears in place of the real one, and what its recognizer says for each time someone speaks.
    var micAudio: URL?
    var micTranscripts: [String]?
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
            micAudio: environment["VOXA_DEBUG_MIC_AUDIO"].map { URL(fileURLWithPath: $0) },
            micTranscripts: environment["VOXA_DEBUG_MIC_TRANSCRIPTS"].map {
                $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            },
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
