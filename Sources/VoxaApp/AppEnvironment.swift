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
    public let settingsWindow: SettingsWindowController
    public let onboardingWindow: OnboardingWindowController
    public let session: VoiceSessionController
    /// Listens continuously while the microphone button in the Voxa bar is on.
    public let handsFree: HandsFreeListener
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
            showWelcome: { welcome.show() }
        )
        let settingsWindow = SettingsWindowController(store: settings, services: services)
        let onboardingWindow = OnboardingWindowController(store: settings, services: services)
        welcome.open = { [weak onboardingWindow] in onboardingWindow?.show() }

        self.settings = settings
        self.permissions = permissions
        self.hotkeys = hotkeys
        self.settingsWindow = settingsWindow
        self.onboardingWindow = onboardingWindow
        self.confirmations = confirmations
        self.agent = agent
        self.keyStores = keyStores
        self.audit = audit
        self.speaker = speaker
        self.settingsServices = services
        self.frontmost = frontmost
        let session = VoiceSessionController(
            capture: MicrophoneCapture(),
            recognizers: DefaultSpeechRecognizerProvider(),
            permissions: permissions,
            hud: bar,
            hotkeys: hotkeys,
            settings: settings,
            openAppSettings: { [weak settingsWindow] in settingsWindow?.show() },
            openModelSettings: { [weak settingsWindow] in settingsWindow?.show(tab: .model) },
            agent: agent,
            confirmations: confirmations,
            speaker: speaker
        )
        // Continuous listening has a microphone of its own, so it never shares the one the push-to-talk key uses: it lets go of it
        // whenever that key, or a command, has need of Voxa.
        var listening = HandsFreeListener.Configuration()
        #if DEBUG
        listening.idleSecondsOverride = overrides.listeningIdleSeconds
        #endif
        let handsFree = HandsFreeListener(
            capture: Self.makeHandsFreeCapture(overrides),
            recognizers: Self.makeHandsFreeRecognizers(overrides),
            permissions: Self.handsFreePermissions(overrides, real: permissions),
            settings: settings,
            host: session,
            configuration: listening
        )

        // The Voxa bar: typing goes to the session, the microphone button to the listener, and the listener's state and loudness come
        // back to the bar.
        bar.model.onSubmit = { [weak session] command in session?.submitCommand(command) ?? false }
        bar.model.onToggleListening = { [weak handsFree] in handsFree?.setOn(!(handsFree?.isOn ?? false)) }
        bar.model.warning = { [weak settings] in settings?.current.fullControl == true ? L10n.Bar.fullControlWarning : nil }
        bar.keepsOpen = { [weak handsFree] in handsFree?.isOn ?? false }
        handsFree.onStateChange = { [weak bar] state in bar?.model.listening = state }
        handsFree.onLevel = { [weak bar] level in bar?.push(level: level) }
        handsFree.onStop = { [weak bar] reason in
            switch reason {
            case .idle(let minutes): bar?.model.note = L10n.Bar.stoppedIdle(minutes)
            }
        }
        self.session = session
        self.handsFree = handsFree
        self.bar = bar
        // Esc, and putting the bar away, stop the microphone too; that needs the finished environment.
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

    /// Puts the bar away, and stops listening: a bar that is gone must not leave a microphone open.
    public func closeBar() {
        handsFree.setOn(false)
        bar.close()
    }

    /// The shortcut: opens the bar, or closes it if it already has the keyboard. If it is showing without the keyboard because it is
    /// listening, the shortcut brings the keyboard back to it; while a command is running there is nothing to type into, and the bar
    /// says so.
    public func toggleBar() {
        if bar.isVisible && bar.hasKeyboard { closeBar() } else { showBar() }
    }

    /// Registers the global shortcuts and starts reacting to them. Call once, after launch.
    public func start() {
        hotkeys.start()
        session.start()
        handsFree.start()
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

    /// The microphone hands-free listens with. A development run can play a file into it instead.
    private static func makeHandsFreeCapture(_ overrides: DevelopmentOverrides) -> any AudioCapturing {
        #if DEBUG
        if let url = overrides.handsFreeAudio { return DebugFileMicrophone(url: url) }
        #endif
        return MicrophoneCapture()
    }

    /// Whose answers decide whether hands-free may listen: the real ones, except that a development run playing a file in place of the
    /// microphone has no microphone to be allowed to use.
    private static func handsFreePermissions(
        _ overrides: DevelopmentOverrides,
        real: SystemPermissionsManager
    ) -> any PermissionsProviding {
        #if DEBUG
        if overrides.handsFreeAudio != nil {
            return ScriptedPermissions([.microphone: .granted, .speechRecognition: .granted], real: real)
        }
        #endif
        return real
    }

    /// The same speech engines a held key uses, all on this Mac. A development run can script what they hear.
    private static func makeHandsFreeRecognizers(_ overrides: DevelopmentOverrides) -> any SpeechRecognizerProviding {
        #if DEBUG
        if let texts = overrides.handsFreeTranscripts { return DebugScriptedTranscripts(texts) }
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
    /// A file hands-free listening hears in place of the microphone, and what its recognizer says for each utterance.
    var handsFreeAudio: URL?
    /// How many seconds of silence switch continuous listening off, in place of the setting (minutes), so a test doesn't wait.
    var listeningIdleSeconds: TimeInterval?
    var handsFreeTranscripts: [String]?
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
            handsFreeAudio: environment["VOXA_DEBUG_HANDSFREE_AUDIO"].map { URL(fileURLWithPath: $0) },
            listeningIdleSeconds: environment["VOXA_DEBUG_LISTENING_IDLE_SECONDS"].flatMap(TimeInterval.init),
            handsFreeTranscripts: environment["VOXA_DEBUG_HANDSFREE_TRANSCRIPTS"].map {
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
