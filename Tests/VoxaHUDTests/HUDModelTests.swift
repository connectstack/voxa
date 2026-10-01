import Foundation
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

    @Test("with a least time between bars, the levels in between become the next bar as the loudest of them, so a short sound isn't lost")
    func levelsAreSpacedOut() {
        var now: TimeInterval = 100
        let model = HUDModel(levelInterval: 0.1, uptime: { now })
        model.push(level: AudioLevel(rms: 0.2, peak: 1))
        #expect(model.levels.last == 0.2, "the first level is a bar at once")

        for level: Float in [0.3, 0.9, 0.4] {
            now += 0.02
            model.push(level: AudioLevel(rms: level, peak: 1))
        }
        #expect(model.levels.last == 0.2, "not long enough since the last bar")

        now += 0.05
        model.push(level: AudioLevel(rms: 0.1, peak: 1))
        #expect(model.levels.last == 0.9, "the next bar is the loudest since the last")
        #expect(model.levels.suffix(3) == [0, 0.2, 0.9])
    }

    @Test("starting a new command starts the meter's spacing afresh")
    func spacingIsResetWithTheSession() {
        let model = HUDModel(levelInterval: 1, uptime: { 5 })
        model.push(level: AudioLevel(rms: 0.5, peak: 1))
        model.resetSession()
        model.push(level: AudioLevel(rms: 0.7, peak: 1))
        #expect(model.levels.last == 0.7, "no need to wait out the last command's interval")
    }

    @Test("a loudness outside 0 to 1 is kept inside it")
    func levelIsClamped() {
        let model = HUDModel()
        model.push(level: AudioLevel(rms: 7, peak: 9))
        model.push(level: AudioLevel(rms: -1, peak: 0))
        #expect(Array(model.levels.suffix(2)) == [1, 0])
    }

    @Test("starting a new command clears the previous transcript and meter but keeps the hint")
    func reset() {
        let model = HUDModel()
        model.hotkeyHint = "⌥Space"
        model.transcript = "open safari"
        model.isTranscriptFinal = true
        model.endsOnClick = true
        model.push(level: AudioLevel(rms: 0.9, peak: 1))

        model.resetSession()

        #expect(model.transcript.isEmpty)
        #expect(!model.isTranscriptFinal)
        #expect(!model.endsOnClick, "how the last command was started says nothing about the next")
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

    @Test("a command being taken, carried out or asked about is in flight, and nothing can be typed then")
    func inFlight() {
        let inFlight: [HUDMode] = [
            .preparing, .listening, .transcribing, .thinking(partial: nil), .acting(title: "Open Safari"), .confirm(sensitivePrompt),
        ]
        for mode in inFlight {
            #expect(mode.isInFlight && !mode.allowsTyping, "\(mode)")
        }
        let finished: [HUDMode] = [
            .idle, .result("x"), .notice(title: "t", detail: nil), .error(UserFacingError(title: "t", detail: "d")), .reply("Done."),
        ]
        for mode in finished {
            #expect(!mode.isInFlight && mode.allowsTyping, "\(mode)")
        }
    }

    @Test("a notice or error with no command before it says its title where the command would be; with one, it doesn't")
    func headline() {
        let model = HUDModel()
        model.mode = .notice(title: "I didn't catch that", detail: "Try again.")
        #expect(model.headline == "I didn't catch that")
        model.mode = .error(UserFacingError(title: "Microphone access is off", detail: "d"))
        #expect(model.headline == "Microphone access is off")

        model.transcript = "open Safari"
        #expect(model.headline == nil, "the command is what the row says then")
        model.transcript = ""
        for mode in [HUDMode.idle, .listening, .thinking(partial: nil), .reply("Done.")] {
            model.mode = mode
            #expect(model.headline == nil, "\(mode)")
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
