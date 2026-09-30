import SwiftUI
import Testing
import VoxaCore
@testable import VoxaHUD

@MainActor
@Suite("CommandBarView rendering")
struct CommandBarViewRenderingTests {
    private func content(
        for mode: HUDMode,
        transcript: String = "Set a timer for five minutes and remind me to stretch afterwards"
    ) -> HUDModel {
        let model = HUDModel()
        model.mode = mode
        model.hotkeyHint = "⌥Space"
        model.transcript = transcript
        for step in 0..<HUDModel.barCount {
            model.push(level: AudioLevel(rms: Float(step % 7) / 8, peak: 1))
        }
        return model
    }

    private func render(_ content: HUDModel, input: CommandBarModel = CommandBarModel()) throws -> CGImage {
        let renderer = ImageRenderer(content: CommandBarView(model: input, content: content))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    @Test(
        "every mode renders at the bar's fixed width with a sensible height",
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
        let image = try render(content(for: mode))
        #expect(image.width == Int(CommandBarView.width) * 2, "expected \(CommandBarView.width) pt at 2x, got \(image.width) px")
        #expect((128...1_400).contains(image.height), "unexpected height \(image.height) px")
    }

    @Test("a bar with nothing to say is only its field: one row, 64 pt tall")
    func idleIsOneRow() throws {
        let image = try render(content(for: .idle, transcript: ""))
        #expect(image.height == 128)
    }

    @Test("with the microphone on, the bar grows a row for the live level and what listening means")
    func listeningAddsARow() throws {
        let input = CommandBarModel()
        input.listening = .listening
        let image = try render(content(for: .idle, transcript: ""), input: input)
        #expect(image.height > 128)
    }

    @Test("a notice with nothing before it says its title in the row, so with no detail it is one row too")
    func headlineNoticeIsOneRow() throws {
        let image = try render(content(for: .notice(title: "I didn't catch that", detail: nil), transcript: ""))
        #expect(image.height == 128)
    }

    @Test("a confirmation is taller than the plain states because it carries the details, but stays bounded for a huge script")
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
            return try render(content(for: .confirm(prompt))).height
        }
        let short = try height(of: "beep")
        let huge = try height(of: String(repeating: "display dialog \"hello world\"\n", count: 200))
        #expect(huge < 2 * 700, "a huge script scrolls inside the card instead of growing it; got \(huge) px")
        #expect(huge >= short)
    }
}
