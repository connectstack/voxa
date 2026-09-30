import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VoxaApp
import VoxaCore
import VoxaHUD
import VoxaTestSupport

/// The Voxa bar as the app wires it: the microphone button, Esc, the shortcut, and what the listener tells it.
/// These use the real environment (and so a real panel), but nothing here starts the microphone or the agent.
@MainActor
@Suite("The Voxa bar in the app", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct VoxaBarWiringTests {
    private func makeEnvironment() -> AppEnvironment {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        // A clean slate: a bar left showing by another test decides whether a new one can take the keyboard.
        for window in NSApp.windows where window is NSPanel { window.orderOut(nil) }
        let suite = "com.rohitsainier.voxa.tests.bar.\(UUID().uuidString)"
        return AppEnvironment(defaults: UserDefaults(suiteName: suite)!, keyboard: FakeKeyboardActivation())
    }

    @Test("the microphone button switches listening on and off, and the bar shows it at once")
    func microphoneButton() async {
        let environment = makeEnvironment()
        #expect(!environment.handsFree.isOn && environment.bar.model.listening == .off)

        environment.bar.model.toggleListening()
        #expect(environment.handsFree.isOn)
        #expect(environment.bar.model.listening == .starting, "the button lights the moment it is clicked")

        environment.bar.model.toggleListening()
        #expect(!environment.handsFree.isOn && environment.bar.model.listening == .off)
    }

    @Test("Esc puts the bar away and stops listening: a bar that is gone must not leave a microphone open")
    func escapeStopsListening() async {
        let environment = makeEnvironment()
        environment.showBar()
        environment.bar.model.toggleListening()
        #expect(environment.bar.isVisible && environment.handsFree.isOn)

        environment.bar.model.escape()
        #expect(!environment.bar.isVisible)
        #expect(!environment.handsFree.isOn)
    }

    @Test("the shortcut opens the bar, and pressed again closes it and stops listening")
    func shortcutToggles() async {
        let environment = makeEnvironment()
        environment.toggleBar()
        #expect(environment.bar.isVisible)
        environment.bar.model.toggleListening()
        environment.toggleBar()
        #expect(!environment.bar.isVisible && !environment.handsFree.isOn)
    }

    @Test("a bar that is listening stays when the person clicks elsewhere; one that isn't goes")
    func staysWhileListening() async throws {
        let environment = makeEnvironment()
        environment.showBar()
        try await Task.sleep(for: .milliseconds(300))
        try #require(environment.bar.debugWindow).resignKey()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!environment.bar.isVisible)

        environment.showBar()
        environment.bar.model.toggleListening()
        try await Task.sleep(for: .milliseconds(300))
        try #require(environment.bar.debugWindow).resignKey()
        try await Task.sleep(for: .milliseconds(100))
        #expect(environment.bar.isVisible, "the microphone is on, so the bar stays where it can be seen")
        environment.closeBar()
    }

    @Test("a command starting, from any source, takes the keyboard from the bar so that what the command types reaches the app in front")
    func commandStartReleasesTheKeyboard() async throws {
        let environment = makeEnvironment()
        environment.showBar()
        environment.bar.model.toggleListening()
        #expect(await waitUntil(timeout: .seconds(5)) { environment.bar.hasKeyboard })

        environment.session.onCommandStarted?()
        try await Task.sleep(for: .milliseconds(150))
        #expect(environment.bar.isVisible, "it is listening, so it stays")
        #expect(!environment.bar.hasKeyboard)
        environment.closeBar()
    }

    @Test("the shortcut on a bar that is showing without the keyboard brings the keyboard back; on one that has it, it closes the bar")
    func shortcutRefocuses() async throws {
        let environment = makeEnvironment()
        environment.showBar()
        environment.bar.model.toggleListening()
        #expect(await waitUntil(timeout: .seconds(5)) { environment.bar.hasKeyboard })
        environment.bar.releaseKeyboard()
        try await Task.sleep(for: .milliseconds(150))
        #expect(environment.bar.isVisible && !environment.bar.hasKeyboard)

        environment.toggleBar()
        #expect(await waitUntil(timeout: .seconds(5)) { environment.bar.hasKeyboard }, "the keyboard is back in the field")
        #expect(environment.bar.isVisible)
        #expect(environment.handsFree.isOn, "and it is still listening")

        environment.toggleBar()
        #expect(!environment.bar.isVisible && !environment.handsFree.isOn)
    }

    @Test("when listening switches itself off for silence, the bar says so")
    func idleStop() async {
        let environment = makeEnvironment()
        environment.handsFree.onStop?(.idle(minutes: 10))
        #expect(environment.bar.model.note == L10n.Bar.stoppedIdle(10))
    }

    @Test("the bar warns about full control while listening, and only then")
    func fullControlWarning() async {
        let environment = makeEnvironment()
        #expect(environment.bar.model.warning() == nil)
        environment.settings.current.fullControl = true
        #expect(environment.bar.model.warning() == L10n.Bar.fullControlWarning)
        environment.settings.current.fullControl = false
        #expect(environment.bar.model.warning() == nil)
    }

    @Test("the microphone's loudness reaches the bar")
    func loudness() async {
        let environment = makeEnvironment()
        environment.handsFree.onLevel?(AudioLevel(rms: 0.5, peak: 0.9))
        #expect(environment.bar.level == 0.5)
    }
}
