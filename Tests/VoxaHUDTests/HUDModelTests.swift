import SwiftUI
import Testing
import VoxaCore
@testable import VoxaHUD

@MainActor
@Suite("HUDModel")
struct HUDModelTests {
    @Test("the meter keeps a fixed number of bars, newest last")
    func levelHistory() {
        let model = HUDModel()
        #expect(model.levels.count == HUDModel.barCount)
        #expect(model.levels.allSatisfy { $0 == 0 })

        for step in 1...(HUDModel.barCount + 5) {
            model.push(level: AudioLevel(rms: Float(step) / 100, peak: 1))
        }
        #expect(model.levels.count == HUDModel.barCount)
        #expect(model.levels.last == Float(HUDModel.barCount + 5) / 100)
        #expect(model.levels.first == Float(6) / 100)  // the five oldest scrolled off
    }

    @Test("starting a new command clears the previous transcript and meter but keeps the hint")
    func reset() {
        let model = HUDModel()
        model.hotkeyHint = "⌥Space"
        model.transcript = "open safari"
        model.isTranscriptFinal = true
        model.push(level: AudioLevel(rms: 0.9, peak: 1))

        model.resetSession()

        #expect(model.transcript.isEmpty)
        #expect(!model.isTranscriptFinal)
        #expect(model.levels.allSatisfy { $0 == 0 })
        #expect(model.hotkeyHint == "⌥Space")
    }

    private let sensitivePrompt = ConfirmationPrompt(
        toolName: "run_applescript",
        title: "Run an AppleScript",
        summary: "Runs a script that controls Finder.",
        details: [
            DetailRow("Script", "tell application \"Finder\" to activate", style: .code),
            DetailRow("Controls", "Finder"),
        ],
        targetApp: "Finder",
        risk: .sensitive,
        reasons: ["AppleScript can control other apps."]
    )

    @Test("a confirmation needs clicks; so does an error with a button; nothing else does")
    func interactivity() {
        #expect(HUDMode.confirm(sensitivePrompt).isInteractive)
        #expect(!HUDMode.thinking(partial: nil).isInteractive)
        #expect(!HUDMode.acting(title: "Open Safari").isInteractive)
        #expect(!HUDMode.reply("Done.").isInteractive)
        #expect(!HUDMode.listening.isInteractive)
        #expect(!HUDMode.result("hi").isInteractive)
        #expect(!HUDMode.error(UserFacingError(title: "t", detail: "d")).isInteractive)
        #expect(HUDMode.error(UserFacingError(title: "t", detail: "d", recovery: .openAppSettings)).isInteractive)
    }

    @Test("each mode shows the right parts")
    func sections() {
        #expect(HUDMode.listening.showsMeter && HUDMode.listening.showsTranscript && HUDMode.listening.showsCancelHint)
        #expect(!HUDMode.transcribing.showsMeter && HUDMode.transcribing.showsCancelHint)
        #expect(HUDMode.result("x").showsTranscript && !HUDMode.result("x").showsCancelHint)
        #expect(!HUDMode.notice(title: "t", detail: nil).showsTranscript)
        #expect(!HUDMode.error(UserFacingError(title: "t", detail: "d")).showsTranscript)

        // The agent's stages keep the command on screen; the question and the reply stand alone.
        for mode in [HUDMode.thinking(partial: nil), .acting(title: "Open Safari")] {
            #expect(mode.showsTranscript && mode.showsCancelHint && !mode.showsMeter)
        }
        for mode in [HUDMode.confirm(sensitivePrompt), .reply("Done.")] {
            #expect(!mode.showsTranscript && !mode.showsCancelHint && !mode.showsMeter)
        }
    }

    @Test("starting a new command also clears the confirmation state")
    func resetClearsConfirmation() {
        let model = HUDModel()
        model.confirmationKeysEnabled = true
        model.answerStatus = .unclear
        model.resetSession()
        #expect(!model.confirmationKeysEnabled)
        #expect(model.answerStatus == .idle)
    }
}

@MainActor
@Suite("HUDView rendering")
struct HUDViewRenderingTests {
    private func model(for mode: HUDMode) -> HUDModel {
        let model = HUDModel()
        model.mode = mode
        model.hotkeyHint = "⌥Space"
        model.transcript = "Set a timer for five minutes and remind me to stretch afterwards"
        for step in 0..<HUDModel.barCount {
            model.push(level: AudioLevel(rms: Float(step % 7) / 8, peak: 1))
        }
        return model
    }

    @Test(
        "every mode renders at the HUD's fixed width with a sensible height",
        arguments: [
            HUDMode.preparing,
            .listening,
            .transcribing,
            .result("Set a timer"),
            .notice(title: "I didn't catch that", detail: "Hold ⌥Space and speak, then release."),
            .error(
                UserFacingError(
                    title: "Microphone access is off",
                    detail: "Turn it on in System Settings.",
                    recovery: .openSystemSettings(.microphone)
                )
            ),
            .thinking(partial: nil),
            .thinking(partial: "Let me open Safari for you."),
            .acting(title: "Open Safari"),
            .reply("Opened Safari and searched for Swift concurrency."),
            .confirm(
                ConfirmationPrompt(
                    toolName: "run_applescript",
                    title: "Run an AppleScript",
                    summary: "Runs a script that controls Finder.",
                    details: [
                        DetailRow("Script", "tell application \"Finder\"\n  activate\nend tell", style: .code),
                        DetailRow("Controls", "Finder"),
                    ],
                    targetApp: "Finder",
                    risk: .sensitive,
                    reasons: [
                        "AppleScript can control other apps.",
                        "Types keystrokes or presses keys in whichever app is in front",
                    ]
                )
            ),
            .confirm(
                ConfirmationPrompt(
                    toolName: "open_url",
                    title: "Open example.com",
                    summary: "Opens example.com in your default app.",
                    details: [
                        DetailRow("Site", "example.com"),
                        DetailRow("Address", "https://example.com/a?b=c", style: .url),
                    ],
                    risk: .reversible,
                    reasons: [
                        "Voxa read content from outside your command (clipboard), so it is double-checking before it acts."
                    ]
                )
            ),
        ]
    )
    func rendersEveryMode(mode: HUDMode) throws {
        let renderer = ImageRenderer(content: HUDView(model: model(for: mode)))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        #expect(image.width == 880, "expected a 440 pt wide HUD at 2x, got \(image.width) px")
        #expect((100...1_400).contains(image.height), "unexpected height \(image.height) px")
    }

    @Test(
        "a confirmation is taller than the plain states because it carries the details, but stays bounded for a huge script"
    )
    func confirmationHeight() throws {
        func height(of script: String) throws -> Int {
            let prompt = ConfirmationPrompt(
                toolName: "run_applescript",
                title: "Run an AppleScript",
                summary: "Runs a script.",
                details: [DetailRow("Script", script, style: .code)],
                risk: .sensitive,
                reasons: ["AppleScript can control other apps."]
            )
            let renderer = ImageRenderer(content: HUDView(model: model(for: .confirm(prompt))))
            renderer.scale = 2
            return try #require(renderer.cgImage).height
        }
        let short = try height(of: "beep")
        let huge = try height(of: String(repeating: "display dialog \"hello world\"\n", count: 200))
        #expect(huge < 2 * 700, "a huge script scrolls inside the card instead of growing it; got \(huge) px")
        #expect(huge >= short)
    }
}
