import AppKit
import Foundation
import Speech
import SwiftUI
import VoxaAgent
import VoxaAudio
import VoxaCore
import VoxaHUD
import VoxaLLM
import VoxaPolicy
import VoxaSettings
import VoxaSpeech
import VoxaTools

// voxa-dev: developer tooling that exercises Voxa's building blocks without a person, a microphone or the full app.
// It is not shipped inside Voxa.app.

let usage = """
    voxa-dev — Voxa developer tools

    USAGE
      voxa-dev transcribe <audio-file> [--engine automatic|classic|analyzer] [--locale en_US] [--realtime]
          Runs a speech engine over a file, printing partial and final transcripts.
          Make a test clip with:  say -o /tmp/clip.aiff "open safari and search for swift concurrency"
          The classic engine needs Speech Recognition permission for the launching app (e.g. Terminal).

      voxa-dev speech-status [--locale en_US]
          Read-only report of what each speech engine can do on this Mac (permissions, models). Downloads nothing.

      voxa-dev hud-snapshots <output-dir> [--scale 2]
          Renders the HUD in every state, in light and dark appearance, to PNG files. Also renders the Settings window.

      voxa-dev system-prompt [--max-steps 12]
          Prints the agent system prompt exactly as it is sent.

      voxa-dev ask "<command>" [--provider anthropic|openai|ollama] [--base-url URL] [--key KEY] [--model ID]
                               [--context TOKENS] [--confirm ask|yes|no[,…]] [--dry-run]
          Runs a typed command through the real agent loop, model client, policy and tools, with no microphone or HUD.
          The key comes from --key, or $ANTHROPIC_API_KEY (claude) / $OPENAI_API_KEY (openai); Ollama needs none. With a
          loopback --base-url (see scripts/mock-llm-server.py) no key is needed either. Ollama needs --model (an installed
          model that can use tools), and --context sets its context window. Confirmations are answered at the terminal (ask),
          or automatically (yes / no).
          --dry-run prints what open_app and open_url would open instead of opening it. AppleScript and Shortcuts still run.

      voxa-dev tools
          Prints every tool's name, description and input schema exactly as they are offered to the model.

      voxa-dev chat "<prompt>" [--provider anthropic|openai|ollama] [--model ID] [--base-url URL] [--key KEY] [--context TOKENS]
          One plain model call with no agent and no tools, streamed to the terminal. The quickest way to check that a key, a
          model name or an Ollama server works. Keys are read as for `ask`.

      voxa-dev ollama [--base-url URL]
          Read-only report of an Ollama server: its version and each installed model with what it can do (tools, thinking,
          context length). Runs nothing and downloads nothing.

      voxa-dev help
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Returns the value following `flag`, if present.
func option(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// MARK: - transcribe

func makeRecognizer(named name: String) -> any SpeechRecognizer {
    switch name {
    case "classic":
        return SFSpeechRecognizerEngine()
    case "analyzer":
        guard #available(macOS 26.0, *) else { fail("The analyzer engine needs macOS 26 or later.") }
        return SpeechAnalyzerEngine()
    case "automatic":
        return DefaultSpeechRecognizerProvider().recognizer(for: AppSettings(speechEngine: .appleAutomatic))
    default:
        fail("Unknown engine '\(name)'. Use automatic, classic or analyzer.")
    }
}

func transcribe(_ arguments: [String]) async {
    guard let path = arguments.first, !path.hasPrefix("--") else { fail("Missing audio file.\n\n\(usage)") }
    let engine = option("--engine", in: arguments) ?? "automatic"
    let locale = Locale(identifier: option("--locale", in: arguments) ?? AppSettings.systemLocaleIdentifier)
    let realTime = arguments.contains("--realtime")

    let recognizer = makeRecognizer(named: engine)
    let capture = FileAudioCapture(url: URL(fileURLWithPath: path), realTime: realTime)
    print("engine: \(engine), locale: \(locale.identifier), file: \(path)")

    do {
        let needs = await recognizer.requiredPermissions(locale: locale)
        print("permissions needed: \(needs.isEmpty ? "none" : needs.map(\.rawValue).sorted().joined(separator: ", "))")

        let streams = try await capture.start()
        let started = Date()
        for try await transcript in recognizer.transcribe(streams.chunks, locale: locale) {
            let elapsed = String(format: "%5.2fs", Date().timeIntervalSince(started))
            print("[\(elapsed)] \(transcript.isFinal ? "FINAL  " : "partial") \(transcript.text)")
        }
    } catch {
        let described = UserFacingError.describing(error)
        fail("error: \(described.title)\n       \(described.detail)")
    }
}

// MARK: - speech-status

func speechStatus(_ arguments: [String]) async {
    let locale = Locale(identifier: option("--locale", in: arguments) ?? AppSettings.systemLocaleIdentifier)
    print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString), locale \(locale.identifier)")

    let authorization = PermissionStatus(SFSpeechRecognizer.authorizationStatus())
    print("classic engine (SFSpeechRecognizer)")
    print("  authorization:       \(authorization)")
    if let recognizer = SFSpeechRecognizer(locale: locale) {
        print("  available:           \(recognizer.isAvailable)")
        print("  on-device supported: \(recognizer.supportsOnDeviceRecognition)")
    } else {
        print("  locale not supported")
    }

    let readiness = await SystemSpeechCapabilityProbe().analyzerReadiness(for: locale)
    print("newer engine (SpeechAnalyzer, macOS 26+)")
    print("  readiness:           \(readiness)  (ready = model installed, needsDownload = supported but not installed)")

    let chosen = DefaultSpeechRecognizerProvider().recognizer(for: AppSettings(speechEngine: .appleAutomatic))
    let needs = await chosen.requiredPermissions(locale: locale)
    print(
        "automatic engine will require: \(needs.isEmpty ? "no permissions" : needs.map(\.rawValue).sorted().joined(separator: ", "))"
    )
}

// MARK: - hud-snapshots

/// One HUD state to render.
struct Snapshot {
    var name: String
    var mode: HUDMode
    var transcript = ""
    var isFinal = false
}

@MainActor
func hudSnapshotList() -> [Snapshot] {

    let stretch = "Set a timer for five minutes and remind me to stretch"
    let longCommand =
        "Open Safari and search for the best restaurants near me that are open late tonight and have "
        + "vegetarian options and outdoor seating, then add the top result to my calendar"
    let plainError = UserFacingError(title: L10n.Errors.noInputDeviceTitle, detail: L10n.Errors.noInputDeviceDetail)

    return [
        Snapshot(name: "preparing", mode: .preparing),
        Snapshot(name: "listening-empty", mode: .listening),
        Snapshot(name: "listening-partial", mode: .listening, transcript: stretch),
        Snapshot(name: "listening-long", mode: .listening, transcript: longCommand),
        Snapshot(name: "transcribing", mode: .transcribing, transcript: stretch, isFinal: true),
        Snapshot(name: "result", mode: .result(stretch), transcript: stretch, isFinal: true),
        Snapshot(
            name: "notice",
            mode: .notice(title: L10n.HUD.didntCatch, detail: L10n.HUD.didntCatchDetail("⌥Space"))
        ),
        Snapshot(name: "error-mic", mode: .error(.permissionRequired(.microphone, status: .denied))),
        Snapshot(name: "error-plain", mode: .error(plainError)),
        Snapshot(name: "thinking", mode: .thinking(partial: nil), transcript: stretch, isFinal: true),
        Snapshot(
            name: "thinking-partial",
            mode: .thinking(partial: "Let me set that timer for you."),
            transcript: stretch,
            isFinal: true
        ),
        Snapshot(name: "acting", mode: .acting(title: "Open Safari"), transcript: stretch, isFinal: true),
        Snapshot(name: "reply", mode: .reply("Done. I opened Safari and searched for Swift concurrency.")),
        Snapshot(
            name: "reply-long",
            mode: .reply(longCommand + ". That is everything I found; the first three results are open in Safari tabs.")
        ),
        Snapshot(name: "confirm-script", mode: .confirm(SamplePrompts.script)),
        Snapshot(name: "confirm-link", mode: .confirm(SamplePrompts.link)),
        Snapshot(name: "confirm-taint", mode: .confirm(SamplePrompts.taint)),
        Snapshot(name: "confirm-long", mode: .confirm(SamplePrompts.longScript)),
    ]
}

@MainActor
func hudSnapshots(_ arguments: [String]) {
    guard let directory = arguments.first, !directory.hasPrefix("--") else {
        fail("Missing output directory.\n\n\(usage)")
    }
    let scale = CGFloat(Double(option("--scale", in: arguments) ?? "2") ?? 2)
    let outputURL = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let snapshots = hudSnapshotList()

    let appearances: [(name: String, appearance: NSAppearance, backdrop: NSColor)] = [
        ("light", NSAppearance(named: .aqua)!, NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.90, alpha: 1)),
        ("dark", NSAppearance(named: .darkAqua)!, NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)),
    ]

    for snapshot in snapshots {
        for (appearanceName, appearance, backdrop) in appearances {
            let model = makeModel(for: snapshot.mode, transcript: snapshot.transcript, isFinal: snapshot.isFinal)
            guard
                let bitmap = renderBitmap(
                    of: HUDView(model: model),
                    appearance: appearance,
                    backdrop: backdrop,
                    scale: scale
                )
            else {
                continue
            }
            let file = outputURL.appendingPathComponent("hud-\(snapshot.name)-\(appearanceName).png")
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("wrote \(file.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
            }
        }
    }
    settingsSnapshots(into: outputURL, scale: scale)
}

enum SamplePrompts {
    static let script = ConfirmationPrompt(
        toolName: "run_applescript",
        title: "Run an AppleScript",
        summary: "Runs an AppleScript that controls Finder.",
        details: [
            DetailRow(
                "Script",
                "tell application \"Finder\"\n  set volume output volume 30\n  activate\nend tell",
                style: .code
            ),
            DetailRow("Controls", "Finder"),
        ],
        targetApp: "Finder",
        risk: .sensitive,
        reasons: [
            "AppleScript can control other apps.", "Types keystrokes or presses keys in whichever app is in front",
        ]
    )
    static let link = ConfirmationPrompt(
        toolName: "open_url",
        title: "Open 192.168.1.1",
        summary: "Opens 192.168.1.1 in your default app.",
        details: [
            DetailRow("Site", "192.168.1.1"),
            DetailRow("Address", "http://192.168.1.1/admin?action=reboot", style: .url),
        ],
        risk: .sensitive,
        reasons: [L10n.Policy.notEncrypted, L10n.Policy.localNetwork]
    )
    static let taint = ConfirmationPrompt(
        toolName: "open_app",
        title: "Open Calculator",
        summary: "Opens Calculator, or brings it to the front if it is already running.",
        details: [DetailRow("App", "Calculator"), DetailRow("Location", "/System/Applications/Calculator.app")],
        targetApp: "Calculator",
        risk: .reversible,
        reasons: [L10n.Policy.taint(["AppleScript output"])]
    )
    static let longScript = ConfirmationPrompt(
        toolName: "run_applescript",
        title: "Run an AppleScript",
        summary: "Runs an AppleScript that controls Notes.",
        details: [
            DetailRow(
                "Script",
                (1...60).map { "make new note with properties {name:\"Note \($0)\", body:\"Body of note \($0)\"}" }
                    .joined(separator: "\n"),
                style: .code
            ),
            DetailRow("Controls", "Notes"),
        ],
        targetApp: "Notes",
        risk: .sensitive,
        reasons: ["AppleScript can control other apps."]
    )
}

@MainActor
func settingsSnapshots(into outputURL: URL, scale: CGFloat) {
    let suite = "com.rohitsainier.voxa.devtools.\(UUID().uuidString)"
    let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)

    /// What to draw: every tab, and the Model tab once for each provider, since it changes with the provider.
    var pages: [(name: String, tab: SettingsView.Tab, provider: ModelProvider)] = []
    for tab in SettingsView.Tab.allCases {
        if tab == .model {
            pages += ModelProvider.allCases.map { ("model-\($0.rawValue.lowercased())", tab, $0) }
        } else {
            pages.append((tab.rawValue, tab, .anthropic))
        }
    }

    for (appearanceName, appearance) in [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
        for page in pages {
            store.current.provider = page.provider
            // The window is a fixed size, so give the view exactly that.
            let view = SettingsView(store: store, navigation: SettingsNavigation(tab: page.tab))
            guard
                let bitmap = renderBitmap(
                    of: view,
                    appearance: appearance,
                    backdrop: .windowBackgroundColor,
                    scale: scale,
                    padding: 0
                )
            else {
                continue
            }
            let file = outputURL.appendingPathComponent("settings-\(page.name)-\(appearanceName).png")
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: file)
                print("wrote \(file.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
            }
        }
    }
}

@MainActor
func makeModel(for mode: HUDMode, transcript: String, isFinal: Bool) -> HUDModel {
    let model = HUDModel()
    model.mode = mode
    model.transcript = transcript
    model.isTranscriptFinal = isFinal
    model.hotkeyHint = "⌥Space"
    for step in 0..<HUDModel.barCount {
        let wave = abs(sin(Double(step) / 3.2)) * 0.6 + 0.05
        model.push(level: AudioLevel(rms: Float(wave), peak: 1))
    }
    return model
}

/// Renders the HUD over a flat backdrop into a bitmap. (System materials can't be captured offscreen, so the panel's
/// translucent background appears flat here; the layout, type and colors are what these images are for.)
@MainActor
func renderBitmap(
    of view: some View,
    appearance: NSAppearance,
    backdrop: NSColor,
    scale: CGFloat,
    padding: CGFloat = 28
) -> NSBitmapImageRep? {
    let host = NSHostingView(rootView: view)
    let size = host.fittingSize
    let canvasFrame = NSRect(x: 0, y: 0, width: size.width + padding * 2, height: size.height + padding * 2)
    let canvas = NSView(frame: canvasFrame)
    canvas.wantsLayer = true
    // Dynamic colors (like the window background) must be resolved for the appearance being rendered, not the app's own.
    var backdropColor = backdrop.cgColor
    appearance.performAsCurrentDrawingAppearance { backdropColor = backdrop.cgColor }
    canvas.layer?.backgroundColor = backdropColor
    host.frame = NSRect(x: padding, y: padding, width: size.width, height: size.height)
    canvas.addSubview(host)

    let window = NSWindow(contentRect: canvasFrame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.contentView = canvas
    canvas.layoutSubtreeIfNeeded()

    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvasFrame.width * scale),
            pixelsHigh: Int(canvasFrame.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }
    bitmap.size = canvasFrame.size
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    return bitmap
}

// MARK: - system-prompt

func systemPrompt(_ arguments: [String]) {
    let steps = Int(option("--max-steps", in: arguments) ?? "12") ?? 12
    do {
        print(try SystemPrompt().render(maxSteps: steps))
    } catch {
        fail("Could not load the system prompt: \(error)")
    }
}

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

    let tools = dryRun ? StandardTools.make(opener: PrintingOpener()) : StandardTools.make()
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

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "transcribe":
    await transcribe(Array(arguments.dropFirst()))
case "speech-status":
    await speechStatus(Array(arguments.dropFirst()))
case "hud-snapshots":
    await MainActor.run { hudSnapshots(Array(arguments.dropFirst())) }
case "system-prompt":
    systemPrompt(Array(arguments.dropFirst()))
case "ask":
    await ask(Array(arguments.dropFirst()))
case "tools":
    printTools()
case "chat":
    await chat(Array(arguments.dropFirst()))
case "ollama":
    await ollamaStatus(Array(arguments.dropFirst()))
case "help", "--help", "-h", nil:
    print(usage)
default:
    fail("Unknown command '\(arguments[0])'.\n\n\(usage)")
}
