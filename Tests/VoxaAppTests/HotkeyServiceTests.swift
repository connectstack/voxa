import KeyboardShortcuts
import Testing
@testable import VoxaApp
import VoxaCore

@MainActor
@Suite("KeyboardShortcutsHotkeyService")
struct HotkeyServiceTests {
    @Test("a key-down becomes a press, and the matching key-up a release")
    func pressAndRelease() async {
        let service = KeyboardShortcutsHotkeyService()
        var events = service.pushToTalk.makeAsyncIterator()

        service.handle(.keyDown)
        #expect(await events.next() == .pressed)
        service.handle(.keyUp)
        #expect(await events.next() == .released)
    }

    /// Regression: an earlier version polled `CGEventSource.keyState` and synthesized a release when it read "up". Without
    /// Input Monitoring permission macOS reports every key as up, so the app ended every hold ~100 ms after the press.
    /// The service must never release on its own: only a real key-up may produce a release, however long the hold.
    @Test("a held key is never released until the key-up arrives")
    func neverReleasesOnItsOwn() async throws {
        let service = KeyboardShortcutsHotkeyService()
        var events = service.pushToTalk.makeAsyncIterator()

        service.handle(.keyDown)
        #expect(await events.next() == .pressed)

        // Hold "for a while" with the run loop turning. Nothing may be emitted.
        try await Task.sleep(for: .milliseconds(400))
        service.handle(.keyUp)
        #expect(await events.next() == .released, "the first event after the press must be the real key-up")

        service.handle(.keyDown)
        #expect(await events.next() == .pressed, "an unexpected extra release would have been delivered first")
    }

    @Test("events are forwarded as delivered; deduplicating is the session controller's job")
    func passThrough() async {
        let service = KeyboardShortcutsHotkeyService()
        var events = service.pushToTalk.makeAsyncIterator()

        service.handle(.keyUp)      // stray
        service.handle(.keyDown)
        service.handle(.keyDown)    // repeat
        service.handle(.keyUp)

        #expect(await events.next() == .released)
        #expect(await events.next() == .pressed)
        #expect(await events.next() == .pressed)
        #expect(await events.next() == .released)
    }

    @Test("the default shortcut is described for menus and the HUD")
    func description() {
        let service = KeyboardShortcutsHotkeyService()
        #expect(service.pushToTalkDescription?.contains("Space") == true)
    }
}
