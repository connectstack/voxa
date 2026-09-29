import AppKit
import CoreGraphics
import Foundation
import Testing
import VoxaCore
@testable import VoxaHUD

/// Real-window tests for the HUD panel. See `SettingsWindowTests` for why these run the run loop: window resizing
/// during AppKit's layout pass is a crash on macOS 26, and only a live display cycle exercises it.
@MainActor
@Suite("HUDController window", .serialized, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct HUDControllerWindowTests {
    private let longTranscript = "Open Safari and search for the best restaurants near me that are open late tonight and have "
        + "vegetarian options and outdoor seating, then add the top result to my calendar"

    private func makeHUD() -> HUDController {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // Windows only run their display cycle once the application has finished launching.
        NSApp.finishLaunching()
        return HUDController()
    }

    /// Waits while yielding the main actor, so the main run loop (display cycle, animations) and any main-actor tasks
    /// the code under test scheduled can actually run. A synchronous nested run loop would block those tasks.
    private func pump(_ seconds: TimeInterval = 0.25) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test("resizing keeps the top edge pinned and the panel centered, whatever the content height")
    func resizeKeepsTopPinned() async throws {
        let hud = makeHUD()
        hud.beginSession()
        hud.show(.listening)
        await pump()

        // The content reports its size through `HUDView`'s preference; drive that path directly, since the SwiftUI
        // layout itself isn't reliable in a test process.
        hud.contentSizeDidChange(CGSize(width: 440, height: 127))
        let first = try #require(hud.panelFrame)
        let screen = try #require(hud.anchorVisibleFrame)

        for height: CGFloat in [187, 66, 110, 97, 240, 66] {
            hud.contentSizeDidChange(CGSize(width: 440, height: height))
            let frame = try #require(hud.panelFrame)
            #expect(frame.width == 440)
            #expect(frame.height == height, "expected \(height), got \(frame.height)")
            #expect(frame.maxY == first.maxY, "the top edge must stay pinned (height \(height))")
            #expect(abs(frame.midX - screen.midX) <= 1, "not centered at height \(height)")
            #expect(abs(frame.maxY - (screen.maxY - 14)) <= 1, "should sit 14 pt below the menu bar")
        }
        hud.hide(after: nil)
        await pump(0.4)
    }

    @Test("a confirmation card accepts clicks and never takes keyboard focus from the app underneath")
    func confirmationIsClickableButNotKey() async throws {
        let hud = makeHUD()
        hud.show(.listening)
        await pump()
        #expect(hud.panelIgnoresMouseEvents == true, "clicks pass through a plain HUD")

        let prompt = ConfirmationPrompt(toolName: "t", title: "Run", summary: "Runs.", risk: .sensitive)
        hud.show(.confirm(prompt))
        await pump()
        #expect(hud.panelIgnoresMouseEvents == false, "the buttons must be clickable")
        #expect(hud.panelCanBecomeKey == false, "the panel must not steal typing focus")

        hud.show(.reply("Done."))
        await pump()
        #expect(hud.panelIgnoresMouseEvents == true, "clicks pass through again once the question is gone")
        hud.hide(after: nil)
        await pump(0.4)
    }

    @Test("a zero or negative reported size is ignored")
    func ignoresDegenerateSizes() async throws {
        let hud = makeHUD()
        hud.beginSession()
        await pump()
        hud.contentSizeDidChange(CGSize(width: 440, height: 100))
        let before = try #require(hud.panelFrame)

        hud.contentSizeDidChange(.zero)
        hud.contentSizeDidChange(CGSize(width: 440, height: 0))
        hud.contentSizeDidChange(CGSize(width: -1, height: 50))
        #expect(hud.panelFrame == before)
        hud.hide(after: nil)
        await pump(0.4)
    }

    @Test("the very first appearance is already centered (not positioned from a zero-sized window)")
    func firstAppearance() async throws {
        let hud = makeHUD()
        hud.beginSession()
        await pump()
        let frame = try #require(hud.panelFrame)
        let screen = try #require(hud.anchorVisibleFrame)
        #expect(abs(frame.midX - screen.midX) <= 1, "panel midX \(frame.midX) vs screen midX \(screen.midX)")
        hud.hide(after: nil)
        await pump(0.4)
    }

    @Test("hundreds of rapid state changes with layout running never crash")
    func stress() async {
        let hud = makeHUD()
        let error = UserFacingError(
            title: "Microphone access is off",
            detail: "Turn it on in System Settings.",
            recovery: .openAppSettings
        )
        let modes: [HUDMode] = [
            .listening,
            .transcribing,
            .result("Set a timer"),
            .notice(title: "Hmm", detail: "Try again."),
            .error(error),
        ]

        hud.beginSession()
        for step in 0..<150 {
            hud.show(modes[step % modes.count])
            hud.setTranscript(step.isMultiple(of: 3) ? longTranscript : "short", isFinal: step.isMultiple(of: 2))
            hud.push(level: AudioLevel(rms: Float(step % 10) / 10, peak: 1))
            await pump(0.004)
        }
        await pump(0.3)
        #expect(hud.isPanelVisible)
        hud.hide(after: nil)
        await pump(0.4)
        #expect(!hud.isPanelVisible)
    }

    @Test("a delayed hide is cancelled by the next show")
    func hideIsCancelled() async {
        let hud = makeHUD()
        hud.show(.listening)
        hud.hide(after: .milliseconds(80))
        hud.show(.result("still here"))
        await pump(0.5)
        #expect(hud.isPanelVisible, "a new show must cancel the pending hide")
        hud.hide(after: nil)
        await pump(0.4)
    }
}
