import AppIntents
import VoxaApp

/// "Hey Siri, ask Voxa" → Siri asks "What should Voxa do?" → you say it → Siri hands the words here.
///
/// Siri does the listening and the speech recognition; Voxa opens no microphone for this. What Siri heard becomes a command exactly
/// as if it had been held-to-talk (`SiriCommand`): the same agent, policy, refusals and Allow cards, and nothing said to Siri can
/// approve one. This lives in the app target, not the package, because the system reads App Intents from the app's own code.
struct GiveVoxaACommand: AppIntent {
    static let title: LocalizedStringResource = "Give Voxa a Command"
    static let description = IntentDescription(
        "Tell Voxa what to do on your Mac, in your own words. Voxa carries it out just as if you had held its shortcut and said it.",
        categoryName: "Voxa"
    )
    /// Voxa lives in the menu bar; running this must not bring anything to the front.
    static let openAppWhenRun = false
    /// A command can drive the whole Mac, so this runs only while the Mac is unlocked.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    /// Siri asks for this when the phrase didn't carry it, listens, and turns the answer into text: that is the hand-over. It is a
    /// command, not prose, so what is typed (Type to Siri, or the Shortcuts app) is left as it was written.
    @Parameter(
        title: "Command",
        description: "What Voxa should do",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none, multiline: false, autocorrect: false, smartQuotes: false, smartDashes: false
        ),
        requestValueDialog: "What should Voxa do?"
    )
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Voxa to \(\.$command)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: IntentDialog
        switch await SiriCommand.run(command) {
        case .started: dialog = "On it."
        case .busy: dialog = "Voxa is busy right now. Try again in a moment."
        case .nothing: dialog = "I didn't catch a command."
        }
        return .result(dialog: dialog)
    }
}

/// The phrases that reach it. Siri needs no set-up: they work once Voxa has been opened, and can be renamed in the Shortcuts app.
struct VoxaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GiveVoxaACommand(),
            phrases: [
                "Ask \(.applicationName)",
                "Tell \(.applicationName)",
                "Give \(.applicationName) a command",
                "\(.applicationName) command",
            ],
            shortTitle: "Give Voxa a Command",
            systemImageName: "waveform"
        )
    }
}
