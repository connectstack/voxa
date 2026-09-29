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
                               [--context TOKENS] [--confirm ask|yes|no[,…]] [--dry-run] [--sample-data]
          Runs a typed command through the real agent loop, model client, policy and tools, with no microphone or HUD.
          The key comes from --key, or $ANTHROPIC_API_KEY (claude) / $OPENAI_API_KEY (openai); Ollama needs none. With a
          loopback --base-url (see scripts/mock-llm-server.py) no key is needed either. Ollama needs --model (an installed
          model that can use tools), and --context sets its context window. Confirmations are answered at the terminal (ask),
          or automatically (yes / no).
          --dry-run prints what open_app and open_url would open instead of opening it. AppleScript and Shortcuts still run.
          --sample-data runs the calendar, reminders, clipboard and front-app tools against made-up data, so nobody's real
          calendar or clipboard is touched. (Without it they use the real ones, with whatever access this terminal has.)

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

// MARK: - system-prompt

func systemPrompt(_ arguments: [String]) {
    let steps = Int(option("--max-steps", in: arguments) ?? "12") ?? 12
    do {
        print(try SystemPrompt().render(maxSteps: steps))
    } catch {
        fail("Could not load the system prompt: \(error)")
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
