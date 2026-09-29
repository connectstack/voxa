import Foundation
import ServiceManagement
import VoxaCore
import VoxaLLM
import VoxaPermissions
import VoxaVoice

/// What the settings screens need from the rest of the app, gathered in one place and passed in, so every screen can be tested
/// and previewed without a Keychain, a network, an installed Ollama, the system's permissions, or a speaker.
public struct SettingsServices: Sendable {
    // The model
    public var keys: [ModelProvider: any APIKeyStoring]
    /// A tiny real request to the chosen provider. Returns nil when it works.
    public var testConnection: @Sendable (ModelProvider) async -> UserFacingError?
    public var ollama: any OllamaDiscovering
    public var openOllama: @MainActor @Sendable () -> Void

    // Everything else
    public var permissions: PermissionsModel
    public var voice: VoiceServices
    public var tools: [ToolInfo]
    public var audit: any AuditReading
    public var launchAtLogin: any LaunchAtLoginControlling
    /// Opens the welcome and permissions walkthrough.
    public var showWelcome: @MainActor @Sendable () -> Void

    public init(
        keys: [ModelProvider: any APIKeyStoring],
        testConnection: @escaping @Sendable (ModelProvider) async -> UserFacingError?,
        ollama: any OllamaDiscovering,
        openOllama: @escaping @MainActor @Sendable () -> Void = {},
        permissions: PermissionsModel,
        voice: VoiceServices,
        tools: [ToolInfo],
        audit: any AuditReading,
        launchAtLogin: any LaunchAtLoginControlling,
        showWelcome: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.keys = keys
        self.testConnection = testConnection
        self.ollama = ollama
        self.openOllama = openOllama
        self.permissions = permissions
        self.voice = voice
        self.tools = tools
        self.audit = audit
        self.launchAtLogin = launchAtLogin
        self.showWelcome = showWelcome
    }

    /// The permissions the Permissions tab lists. Screen Recording joins them when something uses it.
    public static let listedPermissions: [PermissionKind] = [
        .microphone, .speechRecognition, .calendars, .reminders, .accessibility, .automation,
    ]

    /// Nothing behind it: keys are held in memory, every test passes, no Ollama server is ever found, permissions are all
    /// undecided, the history is empty, and speaking does nothing.
    @MainActor
    public static var inert: SettingsServices {
        SettingsServices(
            keys: Dictionary(uniqueKeysWithValues: ModelProvider.allCases.map { ($0, InMemoryAPIKeyStore() as any APIKeyStoring) }),
            testConnection: { _ in nil },
            ollama: OfflineOllama(),
            permissions: PermissionsModel(permissions: UndecidedPermissions(), kinds: listedPermissions),
            voice: .inert,
            tools: [],
            audit: EmptyAuditTrail(),
            launchAtLogin: InertLaunchAtLogin()
        )
    }
}

/// The voices on offer and a way to hear one.
public struct VoiceServices: Sendable {
    public var voices: @MainActor @Sendable () -> [VoiceInfo]
    public var speakSample: @MainActor @Sendable () -> Void

    public init(voices: @escaping @MainActor @Sendable () -> [VoiceInfo], speakSample: @escaping @MainActor @Sendable () -> Void) {
        self.voices = voices
        self.speakSample = speakSample
    }

    public static let inert = VoiceServices(voices: { [] }, speakSample: {})
}

/// One tool as the Tools tab shows it.
public struct ToolInfo: Sendable, Equatable, Identifiable {
    public var name: String
    public var summary: String
    /// How the policy treats it at the least: the higher of what the tool declares and the policy's own floor for it.
    public var risk: RiskLevel
    public var permissions: [PermissionKind]

    public var id: String { name }

    public init(name: String, summary: String, risk: RiskLevel, permissions: [PermissionKind] = []) {
        self.name = name
        self.summary = summary
        self.risk = risk
        self.permissions = permissions
    }
}

// MARK: - Doubles for the inert services

private struct OfflineOllama: OllamaDiscovering {
    func version(at baseURL: URL) async throws -> String { throw LLMError.unreachable(baseURL.host ?? "") }
    func models(at baseURL: URL) async throws -> [OllamaModel] { throw LLMError.unreachable(baseURL.host ?? "") }
    func details(of model: String, at baseURL: URL) async throws -> OllamaModelDetails {
        throw LLMError.unreachable(baseURL.host ?? "")
    }
}

@MainActor
private final class UndecidedPermissions: PermissionsProviding {
    func status(of kind: PermissionKind) -> PermissionStatus { .notDetermined }
    func request(_ kind: PermissionKind) async -> PermissionStatus { .notDetermined }
    func openSystemSettings(for kind: PermissionKind) {}
}

private struct EmptyAuditTrail: AuditReading {
    func readAll() async -> [AuditEntry] { [] }
    func clear() async throws {}
    var location: URL? { nil }
    func sizeOnDisk() async -> Int { 0 }
}

// MARK: - Starting at login

/// Whether Voxa opens itself when the user logs in.
@MainActor
public protocol LaunchAtLoginControlling: Sendable {
    var isEnabled: Bool { get }
    /// macOS wants the user to approve it in System Settings → General → Login Items before it takes effect.
    var needsApproval: Bool { get }
    func setEnabled(_ enabled: Bool) throws
    func openLoginItemsSettings()
}

/// The real thing, through `SMAppService`.
@MainActor
public struct SystemLaunchAtLogin: LaunchAtLoginControlling {
    public init() {}

    public var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
struct InertLaunchAtLogin: LaunchAtLoginControlling {
    var isEnabled: Bool { false }
    var needsApproval: Bool { false }
    func setEnabled(_ enabled: Bool) throws {}
    func openLoginItemsSettings() {}
}
