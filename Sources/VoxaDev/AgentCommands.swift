import AppKit
import Foundation
import Speech
import SwiftUI
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

// Running the agent, one plain model call, and the tool list from a terminal: `voxa-dev ask`, `chat`, `tools`, `ollama`.

// MARK: - ask

/// Answers confirmations at the terminal, or automatically when told to.
final class TerminalConfirmations: ConfirmationProviding, @unchecked Sendable {
    enum Mode: String { case ask, yes, no }
    private let modes: [Mode]
    private let lock = NSLock()
    private var index = 0

    /// One mode per prompt, in order; the last repeats. `--confirm yes,no` allows the first action and declines the second.
    init(modes: [Mode]) {
        self.modes = modes
    }

    private func nextMode() -> Mode {
        lock.lock()
        defer { lock.unlock() }
        let mode = modes[min(index, modes.count - 1)]
        index += 1
        return mode
    }

    func confirm(_ prompt: ConfirmationPrompt) async -> ConfirmationOutcome {
        let mode = nextMode()
        print("")
        print("── Voxa asks permission ─────────────────────────────")
        print("  \(prompt.title)  [\(prompt.risk)]")
        print("  \(prompt.summary)")
        for row in prompt.details {
            print("  \(row.label): \(row.value.replacingOccurrences(of: "\n", with: "\n      "))")
        }
        for reason in prompt.reasons { print("  ! \(reason)") }
        switch mode {
        case .yes:
            print("  → allowed automatically (--confirm yes)")
            return .approved
        case .no:
            print("  → declined automatically (--confirm no)")
            return .denied
        case .ask:
            print("  Allow? [y/N] ", terminator: "")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return answer == "y" || answer == "yes" ? .approved : .denied
        }
    }
}

struct PrintingOpener: AppOpening {
    func open(_ app: InstalledApp) async throws { print("  (dry run) would open the app \(app.name)") }
    func open(_ url: URL, in app: InstalledApp?) async throws {
        print("  (dry run) would open \(url.absoluteString)\(app.map { " in \($0.name)" } ?? "")")
    }
}

actor PrintingAuditLog: AuditLogging {
    func record(_ entry: AuditEntry) {
        let parts = [entry.kind.rawValue, entry.tool, entry.risk.map { "\($0)" }, entry.outcome].compactMap { $0 }
        FileHandle.standardError.write(Data(("  audit: " + parts.joined(separator: " ") + "\n").utf8))
    }
}

/// The provider, settings and client a command-line invocation asks for. Keys are used to build the client and never printed.
struct ProviderSetup {
    var provider: ModelProvider
    var settings: AppSettings
    var llm: RoutingLLMClient

    init(_ arguments: [String]) {
        let providerName = option("--provider", in: arguments) ?? "anthropic"
        guard let provider = ModelProvider.allCases.first(where: { $0.rawValue.lowercased() == providerName.lowercased() }) else {
            fail("--provider must be anthropic, openai or ollama.")
        }
        let baseURL = option("--base-url", in: arguments).flatMap(URL.init(string:))
        let isLoopback = baseURL?.host.map { ["127.0.0.1", "localhost", "::1"].contains($0) } ?? false
        let environment = ProcessInfo.processInfo.environment

        let key: String?
        switch provider {
        case .anthropic:
            key = option("--key", in: arguments) ?? environment["ANTHROPIC_API_KEY"] ?? (isLoopback ? "sk-ant-mock" : nil)
        case .openAI:
            key = option("--key", in: arguments) ?? environment["OPENAI_API_KEY"] ?? (isLoopback ? "sk-mock" : nil)
        case .ollama:
            key = nil
        }
        if provider.usesAPIKey, key == nil {
            let variable = provider == .openAI ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"
            fail("No API key. Pass --key, or set \(variable), or use a loopback --base-url.")
        }

        var chosen = AppSettings()
        chosen.provider = provider
        switch provider {
        case .anthropic:
            chosen.model = option("--model", in: arguments) ?? AppSettings.defaultModel
        case .openAI:
            chosen.openAIModel = option("--model", in: arguments) ?? AppSettings.defaultOpenAIModel
            chosen.openAIBaseURL = baseURL?.absoluteString ?? AppSettings.defaultOpenAIBaseURL
        case .ollama:
            guard let model = option("--model", in: arguments) else {
                fail("Ollama needs --model: the name of an installed model that can use tools (see `ollama list`).")
            }
            chosen.ollamaModel = model
            chosen.ollamaBaseURL = baseURL?.absoluteString ?? AppSettings.defaultOllamaBaseURL
            chosen.ollamaContextLength =
                option("--context", in: arguments).flatMap(Int.init) ?? AppSettings.defaultOllamaContextLength
        }

        self.provider = provider
        self.settings = chosen
        self.llm = RoutingLLMClient(
            anthropic: AnthropicClient(
                keys: InMemoryAPIKeyStore(key: provider == .anthropic ? key : nil),
                baseURL: (provider == .anthropic ? baseURL : nil) ?? AnthropicClient.officialBaseURL
            ),
            openAI: OpenAIClient(keys: InMemoryAPIKeyStore(key: provider == .openAI ? key : nil)),
            ollama: OllamaClient()
        )
    }
}

func ask(_ arguments: [String]) async {
    guard let command = arguments.first, !command.hasPrefix("--") else { fail("Missing command.\n\n\(usage)") }
    let setup = ProviderSetup(arguments)
    let provider = setup.provider
    let settings = setup.settings
    let llm = setup.llm

    let modes = (option("--confirm", in: arguments) ?? "ask").split(separator: ",").compactMap {
        TerminalConfirmations.Mode(rawValue: String($0))
    }
    guard !modes.isEmpty else { fail("--confirm must be ask, yes or no (or a comma-separated list, one per prompt).") }
    let dryRun = arguments.contains("--dry-run")

    // The calendar, reminders, clipboard and front-app tools touch the real ones unless asked to use made-up sample data.
    let system: SystemAccess = arguments.contains("--sample-data") ? .sample() : .real()
    let tools = dryRun ? StandardTools.make(opener: PrintingOpener(), system: system) : StandardTools.make(system: system)
    let prompt: SystemPrompt
    do { prompt = try SystemPrompt() } catch { fail("Could not load the system prompt: \(error)") }

    let service = AgentService(
        llm: llm,
        registry: ToolRegistry(tools),
        confirmations: TerminalConfirmations(modes: modes),
        audit: PrintingAuditLog(),
        systemPrompt: prompt,
        settings: { settings }
    )
    print("provider: \(provider.rawValue)  model: \(settings.activeModel)")
    print("command: \(command)")
    let result = await service.run(command) { event in
        switch event {
        case .thinking(let step): print("  thinking (step \(step))")
        case .acting(let title): print("  acting: \(title)")
        case .finishedTool(let title, let ok, let notice):
            print("  finished: \(title) \(ok ? "✓" : "✗")\(notice.map { " — \($0)" } ?? "")")
        case .retrying: print("  retrying…")
        case .awaitingConfirmation, .replyText: break
        }
    }
    print("")
    print("outcome: \(result.outcome.auditWord)  steps: \(result.steps)  actions: \(result.actions)")
    print("reply: \(result.reply)")
    if case .failed(let error) = result.outcome { print("error: \(error.title) — \(error.detail)") }
}

// MARK: - tools

func printTools() {
    let registry = ToolRegistry(StandardTools.make())
    for definition in registry.definitions(excluding: []) {
        print("\(definition.name): \(definition.description)")
        print(definition.inputSchema.serialized(pretty: true))
        print("")
    }
}

// MARK: - chat

/// One plain model call: no agent, no tools, no policy. Streams the text as it arrives.
func chat(_ arguments: [String]) async {
    guard let prompt = arguments.first, !prompt.hasPrefix("--") else { fail("Missing prompt.\n\n\(usage)") }
    let setup = ProviderSetup(arguments)
    let settings = setup.settings
    print("provider: \(setup.provider.rawValue)  model: \(settings.activeModel)")
    fflush(stdout)   // the answer below is written unbuffered, so this line has to be out first

    let request = LLMRequest(
        model: settings.activeModel,
        maxTokens: 400,
        system: [SystemBlock("You are a concise assistant. Answer in one or two short sentences.")],
        messages: [.user(prompt)],
        effort: .low,
        provider: setup.provider,
        endpoint: settings.activeBaseURL,
        contextLength: setup.provider == .ollama ? settings.ollamaContextLength : nil
    )
    let started = Date()
    do {
        let response = try await setup.llm.complete(request) { event in
            if case .blockDelta(_, .text(let piece)) = event {
                FileHandle.standardOutput.write(Data(piece.utf8))
            }
        }
        let seconds = Date().timeIntervalSince(started)
        print("")
        print(
            "stop: \(String(describing: response.stopReason))  tokens in/out: \(response.usage.inputTokens)/\(response.usage.outputTokens)"
                + String(format: "  time: %.1fs", seconds)
        )
    } catch {
        let failure = UserFacingError.describing(error)
        print("")
        print("error: \(failure.title) — \(failure.detail)")
        exit(1)
    }
}

// MARK: - ollama

func ollamaStatus(_ arguments: [String]) async {
    let text = option("--base-url", in: arguments) ?? AppSettings.defaultOllamaBaseURL
    guard let address = OllamaClient.address(from: text) else { fail("That isn't a usable address: \(text)") }
    let discovery = OllamaDiscovery()
    do {
        print("server: \(address.absoluteString)  version: \(try await discovery.version(at: address))")
        let models = try await discovery.models(at: address)
        print("\(models.count) models")
        for model in models {
            var line = "  \(model.name)"
            if let size = model.parameterSize { line += "  \(size)" }
            if model.isCloud { line += "  [cloud: runs on Ollama's servers]" }
            print(line)
            // A cloud model's details are fetched from Ollama's servers; a read-only report shouldn't reach out for them.
            if !model.isCloud, let details = try? await discovery.details(of: model.name, at: address) {
                let thinking: String
                switch details.thinking {
                case .unsupported: thinking = "no"
                case .toggle: thinking = "on/off"
                case .levels(let levels): thinking = levels.joined(separator: "/")
                case .always: thinking = "always"
                }
                print(
                    "      tools: \(details.supportsTools ? "yes" : "no")  thinking: \(thinking)  "
                        + "max context: \(details.contextLength.map(String.init) ?? "?")  capabilities: \(details.capabilities.sorted().joined(separator: ","))"
                )
            }
        }
    } catch {
        let failure = UserFacingError.describing(
            (error as? LLMError).map { ProviderFailure(provider: .ollama, error: $0) } ?? error
        )
        fail("\(failure.title) — \(failure.detail)")
    }
}
