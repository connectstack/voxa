import AppKit
import Foundation
import VoxaCore
@testable import VoxaHUD
import VoxaTestSupport

/// What the bar's real-window suites share.
@MainActor
enum BarWindowFixture {
    static let question = ConfirmationPrompt(toolName: "t", title: "Run", summary: "Runs.", risk: .sensitive)

    static func makeBar(_ activation: FakeKeyboardActivation = FakeKeyboardActivation()) -> CommandBarController {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        // Windows only run their display cycle once the application has finished launching.
        NSApp.finishLaunching()
        // A clean slate: a bar left showing by another test decides whether a new one can take the keyboard.
        for window in NSApp.windows where window is NSPanel { window.orderOut(nil) }
        return CommandBarController(activation: activation)
    }

    /// Waits while yielding the main actor, so the main run loop (display cycle, animations) and any main-actor tasks the code under
    /// test scheduled can actually run. A synchronous nested run loop would block those tasks.
    static func pump(_ seconds: TimeInterval = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Waits for the bar to have the keyboard. Key status comes from AppKit on its own schedule, which a busy test process can make slow.
    static func hasKeyboard(_ bar: CommandBarController) async -> Bool {
        await waitUntil(timeout: .seconds(5)) { bar.hasKeyboard }
    }
}
