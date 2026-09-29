import AppKit
import Foundation
import VoxaCore

/// Starts the Ollama app, which runs the local model server. Used by the "Open Ollama" button on the error that says the
/// server isn't running.
@MainActor
enum OllamaLauncher {
    static let bundleIdentifier = "com.electron.ollama"

    /// The installed app, if there is one.
    static var applicationURL: URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) { return url }
        let fallback = URL(fileURLWithPath: "/Applications/Ollama.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static var isInstalled: Bool { applicationURL != nil }

    static func launch() {
        guard let url = applicationURL else {
            // Not installed: send the user to where they can get it.
            if let download = URL(string: "https://ollama.com/download") { NSWorkspace.shared.open(download) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false   // it lives in the menu bar; the user's current app should stay in front
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { Log.app.error("could not start Ollama: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

extension VoiceSessionController {
    func openOllama() {
        OllamaLauncher.launch()
    }
}
