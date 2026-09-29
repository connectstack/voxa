#if DEBUG
import Foundation
import notify
import VoxaCore
import VoxaHUD
import VoxaSettings

/// States the debug tooling can pin the HUD to, so its layout, position and focus behavior can be inspected without a
/// microphone or a key press. Compiled into Debug builds only.
enum DebugHUDState: String, CaseIterable {
    case listening, partial, long, transcribing, result, notice, error, errorPlain, hide
    case thinking, thinkingPartial, acting, reply, replyLong
    case confirmScript, confirmURL, confirmTaint, confirmLong

    var title: String {
        switch self {
        case .listening: "Listening (empty)"
        case .partial: "Listening (partial transcript)"
        case .long: "Listening (long transcript)"
        case .transcribing: "Transcribing"
        case .result: "Result"
        case .notice: "Notice"
        case .error: "Error with button"
        case .errorPlain: "Error"
        case .hide: "Hide"
        case .thinking: "Thinking"
        case .thinkingPartial: "Thinking (with partial reply)"
        case .acting: "Acting"
        case .reply: "Reply"
        case .replyLong: "Reply (long)"
        case .confirmScript: "Confirm: AppleScript"
        case .confirmURL: "Confirm: risky link"
        case .confirmTaint: "Confirm: after outside content"
        case .confirmLong: "Confirm: very long script"
        }
    }
}

/// Opt-in transcript capture for verifying speech recognition from a shell. Only compiled into Debug builds, and only
/// active when the app was launched with `VOXA_DEBUG_TRANSCRIPT_FILE=/some/path` (e.g. `open --env VAR=path Voxa.app`).
/// Release builds never contain this, and nothing is written unless the variable is set.
enum DebugTranscriptDump {
    static func write(_ text: String) {
        guard let path = ProcessInfo.processInfo.environment["VOXA_DEBUG_TRANSCRIPT_FILE"] else { return }
        try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Sample confirmation prompts for inspecting the card's layout.
enum DebugPrompts {
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

/// The name of a debug notification (`com.rohitsainier.voxa.debug.<name>`). A test run sets `VOXA_DEBUG_HOOK_SUFFIX`, which is added
/// to every name, so the run's notifications belong to that one copy of the app: another Voxa on the same Mac (one someone is
/// using, or a build from before this existed) has no suffix, so it neither hears them nor sends them.
private func debugHook(_ name: String) -> String {
    let base = "com.rohitsainier.voxa.debug." + name
    guard let suffix = ProcessInfo.processInfo.environment["VOXA_DEBUG_HOOK_SUFFIX"], !suffix.isEmpty else { return base }
    return base + "." + suffix
}

extension AppEnvironment {
    /// Post `notifyutil -p com.rohitsainier.voxa.debug.hud.<state>` from a shell to pin the HUD to that state.
    func installDebugHooks() {
        for state in DebugHUDState.allCases {
            var token: Int32 = 0
            notify_register_dispatch(debugHook("hud.\(state.rawValue)"), &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showDebugHUD(state) }
            }
        }

        // Inject the same events KeyboardShortcuts would deliver for the push-to-talk key, so the real pipeline (controller,
        // permissions, microphone, speech engine, HUD) can be driven from a shell without a physical key press:
        //   notifyutil -p com.rohitsainier.voxa.debug.key.down ; say "open safari" ; notifyutil -p com.rohitsainier.voxa.debug.key.up
        var keyDownToken: Int32 = 0
        notify_register_dispatch(debugHook("key.down"), &keyDownToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeys.handle(.keyDown) }
        }
        var keyUpToken: Int32 = 0
        notify_register_dispatch(debugHook("key.up"), &keyUpToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeys.handle(.keyUp) }
        }

        // Drive the agent without the microphone. The command is read from the file named by VOXA_DEBUG_COMMAND_FILE:
        //   echo "open safari" > /tmp/cmd.txt ; notifyutil -p com.rohitsainier.voxa.debug.ask
        var askToken: Int32 = 0
        notify_register_dispatch(debugHook("ask"), &askToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard
                    let path = ProcessInfo.processInfo.environment["VOXA_DEBUG_COMMAND_FILE"],
                    let text = try? String(contentsOfFile: path, encoding: .utf8)
                else { return }
                self?.session.debugSubmit(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // Keys (Esc, ⌘Return) and answers a confirmation would receive, and a report of which keys are captured right now.
        var returnToken: Int32 = 0
        notify_register_dispatch(debugHook("key.allow"), &returnToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeys.debugPressAllow() }
        }
        var escapeToken: Int32 = 0
        notify_register_dispatch(debugHook("key.escape"), &escapeToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeys.debugPressEscape() }
        }
        for (name, phrase) in [("yes", "yes"), ("no", "no"), ("unclear", "maybe later")] {
            var token: Int32 = 0
            notify_register_dispatch(debugHook("answer.\(name)"), &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.confirmations.submitSpokenAnswer(phrase) }
            }
        }
        var denyToken: Int32 = 0
        notify_register_dispatch(debugHook("button.deny"), &denyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hud.pressConfirmationButton(.deny) }
        }
        var allowToken: Int32 = 0
        notify_register_dispatch(debugHook("button.allow"), &allowToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hud.pressConfirmationButton(.allow) }
        }
        var recoveryToken: Int32 = 0
        notify_register_dispatch(debugHook("button.recovery"), &recoveryToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hud.pressRecoveryButton() }
        }
        // `debug.report` writes the current status to VOXA_DEBUG_REPORT_FILE (one line, key=value pairs).
        var reportToken: Int32 = 0
        notify_register_dispatch(debugHook("report"), &reportToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeDebugReport() }
        }

        installSettingsDebugHooks()
    }

    /// Hooks that open and close the Settings window, the way the menu item and an error's button do.
    private func installSettingsDebugHooks() {
        // `notifyutil -p com.rohitsainier.voxa.debug.settings` opens the Settings window exactly as the menu item does.
        var settingsToken: Int32 = 0
        notify_register_dispatch(debugHook("settings"), &settingsToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindow.show() }
        }
        // Same, but executed inside the run loop's event-tracking mode, the context a menu-item action runs in.
        var trackingToken: Int32 = 0
        let trackingName = debugHook("settings.tracking")
        notify_register_dispatch(trackingName, &trackingToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                RunLoop.current.perform(inModes: [.eventTracking]) {
                    MainActor.assumeIsolated { self?.settingsWindow.show() }
                }
                RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.8))
            }
        }
        // The same, on a given tab, as an error's "Open Settings" button does for a model problem.
        for tab in SettingsView.Tab.allCases {
            let name = tab.rawValue
            var tabToken: Int32 = 0
            notify_register_dispatch(debugHook("settings.tab.\(name)"), &tabToken, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsWindow.show(tab: tab) }
            }
        }
        // Change the provider as the Settings picker does (it writes the same property), with the window open or not.
        for provider in ModelProvider.allCases {
            var providerToken: Int32 = 0
            let name = debugHook("provider.\(provider.rawValue.lowercased())")
            notify_register_dispatch(name, &providerToken, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settings.current.provider = provider }
            }
        }
        // The first-run walkthrough, and speaking a reply as if the agent had produced it (`say.txt` is read from
        // VOXA_DEBUG_SAY_FILE), so both can be seen and heard without setting up a first run or a command.
        var welcomeToken: Int32 = 0
        notify_register_dispatch(debugHook("onboarding"), &welcomeToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboardingWindow.show() }
        }
        for step in 0..<WelcomePreview.stepCount {
            var stepToken: Int32 = 0
            notify_register_dispatch(debugHook("onboarding.step.\(step)"), &stepToken, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onboardingWindow.show(step: step) }
            }
        }
        // The button in Settings → General that opens the guide, pressed through the services Settings itself is given.
        var welcomeButtonToken: Int32 = 0
        notify_register_dispatch(debugHook("button.welcomeGuide"), &welcomeButtonToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsServices.showWelcome() }
        }
        var welcomeCloseToken: Int32 = 0
        notify_register_dispatch(debugHook("onboarding.close"), &welcomeCloseToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboardingWindow.close() }
        }
        var sayToken: Int32 = 0
        notify_register_dispatch(debugHook("say"), &sayToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard
                    let path = ProcessInfo.processInfo.environment["VOXA_DEBUG_SAY_FILE"],
                    let text = try? String(contentsOfFile: path, encoding: .utf8)
                else { return }
                self?.speaker.speakReply(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        var closeToken: Int32 = 0
        notify_register_dispatch(debugHook("settings.close"), &closeToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindow.close() }
        }
    }

    private func writeDebugReport() {
        guard let path = ProcessInfo.processInfo.environment["VOXA_DEBUG_REPORT_FILE"] else { return }
        let counts = hotkeys.debugListenerCounts
        let line =
            "status=\(session.status) stage=\(String(describing: session.agentStage)) awaiting=\(confirmations.isAwaitingAnswer) "
            + "escapeListeners=\(counts.escape) allowListeners=\(counts.allowKey) "
            + "mic=\(permissions.status(of: .microphone)) speech=\(permissions.status(of: .speechRecognition)) "
            + "provider=\(settings.current.provider.rawValue) settingsTab=\(settingsWindow.selectedTab.rawValue) "
            + "welcome=\(onboardingWindow.isVisible) speaking=\(speaker.isSpeaking) "
            + "accessibility=\(permissions.status(of: .accessibility)) "
            + "hasKey=\(keyStores[settings.current.provider]?.hasKey() ?? false)\n"
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func showDebugHUD(_ state: DebugHUDState) {
        hud.hotkeyHint = hotkeys.pushToTalkDescription ?? "⌥Space"
        let sample = "Set a timer for five minutes and remind me to stretch"
        let long =
            "Open Safari and search for the best restaurants near me that are open late tonight and have "
            + "vegetarian options and outdoor seating, then add the top result to my calendar"

        func meter() {
            for step in 0..<HUDModel.barCount {
                hud.push(level: AudioLevel(rms: Float(abs(sin(Double(step) / 3.2)) * 0.6 + 0.05), peak: 1))
            }
        }

        switch state {
        case .listening:
            hud.beginSession(); meter(); hud.show(.listening)
        case .partial:
            hud.beginSession(); meter(); hud.setTranscript(sample, isFinal: false); hud.show(.listening)
        case .long:
            hud.beginSession(); meter(); hud.setTranscript(long, isFinal: false); hud.show(.listening)
        case .transcribing:
            hud.beginSession(); hud.setTranscript(sample, isFinal: false); hud.show(.transcribing)
        case .result:
            showCommandCard(sample, .result(sample))
        case .notice:
            hud.show(.notice(title: L10n.HUD.didntCatch, detail: L10n.HUD.didntCatchDetail(hud.hotkeyHint ?? "⌥Space")))
        case .error:
            hud.show(.error(.permissionRequired(.microphone, status: .denied)))
        case .errorPlain:
            hud.show(
                .error(UserFacingError(title: L10n.Errors.noInputDeviceTitle, detail: L10n.Errors.noInputDeviceDetail))
            )
        case .hide:
            hud.hide(after: nil)
        case .thinking:
            showCommandCard(sample, .thinking(partial: nil))
        case .thinkingPartial:
            showCommandCard(sample, .thinking(partial: "Let me set that timer for you."))
        case .acting:
            showCommandCard(sample, .acting(title: "Open Safari"))
        case .reply:
            hud.show(.reply("Done. I opened Safari and searched for Swift concurrency."))
        case .replyLong:
            let tail = ". That is everything I found; the first three results are open in Safari tabs, "
                + "and I added the best one to your calendar for tonight at eight."
            hud.show(.reply(long + tail))
        case .confirmScript:
            showDebugConfirmation(DebugPrompts.script)
        case .confirmURL:
            showDebugConfirmation(DebugPrompts.link)
        case .confirmTaint:
            showDebugConfirmation(DebugPrompts.taint)
        case .confirmLong:
            showDebugConfirmation(DebugPrompts.longScript)
        }
    }

    /// A card that shows the recognized command with `mode` in front of it, as the real flow does.
    private func showCommandCard(_ command: String, _ mode: HUDMode) {
        hud.beginSession()
        hud.setTranscript(command, isFinal: true)
        hud.show(mode)
    }

    private func showDebugConfirmation(_ prompt: ConfirmationPrompt) {
        hud.show(.confirm(prompt))
        hud.setConfirmationKeysEnabled(true)
    }
}
#endif
