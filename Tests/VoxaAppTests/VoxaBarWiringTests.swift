import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import VoxaApp
import VoxaCore
import VoxaHUD
import VoxaTestSupport

/// The Voxa bar as the app wires it: the microphone button, Esc, the shortcut, and what the session tells it.
/// These use the real environment (and so a real panel), but nothing here starts the microphone or the agent: a click on the button
/// would open the real microphone, so the click's own behaviour is tested against the session with fakes (`ClickToTalkTests`).
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

    @Test("the microphone button is wired to the session, and nothing listens until it is clicked")
    func microphoneButtonIsWired() {
        let environment = makeEnvironment()
        #expect(environment.bar.model.onMicrophone != nil)
        #expect(!environment.session.isMicrophoneOpen)
        #expect(!environment.bar.keepsOpen(), "a bar nobody is talking to is not held open")
    }

    @Test("Esc puts the bar away")
    func escapePutsTheBarAway() {
        let environment = makeEnvironment()
        environment.showBar()
        #expect(environment.bar.isVisible)

        environment.bar.model.escape()
        #expect(!environment.bar.isVisible)
    }

    @Test("the shortcut opens the bar, and pressed again closes it")
    func shortcutToggles() {
        let environment = makeEnvironment()
        environment.toggleBar()
        #expect(environment.bar.isVisible)
        environment.toggleBar()
        #expect(!environment.bar.isVisible)
    }

    @Test("a bar that isn't being talked to goes when the person clicks elsewhere")
    func goesWhenClickedAway() async throws {
        let environment = makeEnvironment()
        environment.showBar()
        try await Task.sleep(for: .milliseconds(300))
        try #require(environment.bar.debugWindow).resignKey()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!environment.bar.isVisible)
    }

    @Test("a command starting, from any source, takes the keyboard from the bar so that what the command types reaches the app in front")
    func commandStartReleasesTheKeyboard() async throws {
        let environment = makeEnvironment()
        environment.showBar()
        #expect(await waitUntil(timeout: .seconds(5)) { environment.bar.hasKeyboard })

        environment.session.onCommandStarted?()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!environment.bar.hasKeyboard)
        #expect(!environment.bar.isVisible, "with no command shown yet and nobody talking to it, there is nothing left for the bar to be")
    }

    @Test("the bar warns about full control, and only while it is on")
    func fullControlWarning() {
        let environment = makeEnvironment()
        #expect(environment.bar.model.warning() == nil)
        environment.settings.current.fullControl = true
        #expect(environment.bar.model.warning() == L10n.Bar.fullControlWarning)
        environment.settings.current.fullControl = false
        #expect(environment.bar.model.warning() == nil)
    }

    @Test("the microphone's loudness reaches the bar: the session does the listening, and shows it on the bar it presents to")
    func loudness() {
        let environment = makeEnvironment()
        environment.session.hud.push(level: AudioLevel(rms: 0.5, peak: 0.9))
        #expect(environment.bar.level == 0.5)
    }
}
