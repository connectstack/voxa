import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import VoxaCore
@testable import VoxaHUD
import VoxaTestSupport

/// A real mouse click on the bar's microphone button, as AppKit delivers it to the real panel. The button is the one way to start and
/// to send a command by voice from the bar, so it must take a click in every state it is shown in: with the keyboard (the bar was just
/// opened), and without it (the bar is listening, the app in front has the keyboard, and the person comes back to click it again).
@MainActor
@Suite("The microphone button takes real clicks", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct CommandBarMicrophoneClickTests {
    /// Where the button is in the window: at the right end of the first row, 13 pt in from the edge and 38 pt across, in a row at
    /// least 64 pt tall at the top of the card.
    private func microphoneCentre(in window: NSWindow) -> NSPoint {
        let bounds = window.contentView?.bounds ?? .zero
        return NSPoint(x: bounds.width - 13 - 19, y: bounds.height - 32)
    }

    private func click(at point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )!
            window.sendEvent(event)
        }
    }

    @Test("with the bar open and nothing under way, a click on the microphone reaches the app")
    func clickWhenOpen() async throws {
        let bar = BarWindowFixture.makeBar()
        var clicks = 0
        bar.model.onMicrophone = { clicks += 1 }
        bar.open()
        await BarWindowFixture.pump()
        defer { bar.close() }

        let window = try #require(bar.window)
        click(at: microphoneCentre(in: window), in: window)
        #expect(clicks == 1)
    }

    @Test("with the bar showing but the keyboard elsewhere (the app in front has it), a click on the microphone still reaches the app")
    func clickWithoutTheKeyboard() async throws {
        let bar = BarWindowFixture.makeBar()
        var clicks = 0
        bar.model.onMicrophone = { clicks += 1 }
        // The bar stays where it can be seen while the microphone button has Voxa listening, even when the person clicks elsewhere.
        bar.keepsOpen = { true }
        bar.open()
        await BarWindowFixture.pump()
        let window = try #require(bar.window)
        // The person clicked into another app: the bar is still up, and no longer has the keyboard.
        if window.isKeyWindow { window.resignKey() }
        await BarWindowFixture.pump()
        defer {
            bar.keepsOpen = { false }
            bar.close()
        }

        #expect(!bar.hasKeyboard)
        #expect(bar.isVisible && bar.model.isOpen)
        click(at: microphoneCentre(in: window), in: window)
        #expect(clicks == 1, "the first click on a panel that doesn't have the keyboard must not be spent on giving it the keyboard")
    }

    @Test("while it listens, the bar can't take the keyboard at all, and the click that sends still reaches the app")
    func clickWhileListening() async throws {
        let bar = BarWindowFixture.makeBar()
        var clicks = 0
        bar.model.onMicrophone = { clicks += 1 }
        bar.keepsOpen = { true }
        bar.open()
        // What the session does once the button has been clicked: it begins, shows the microphone listening, and says a click ends it.
        bar.beginSession()
        bar.setListeningEndsOnClick(true)
        bar.show(.listening)
        bar.releaseKeyboard()
        // In the app the panel takes its height from SwiftUI's own measurement; here the same measurement is made by hand.
        let measured = HUDModel()
        measured.mode = .listening
        measured.endsOnClick = true
        let probe = NSHostingView(rootView: CommandBarView(model: bar.model, content: measured))
        probe.layoutSubtreeIfNeeded()
        let height = probe.fittingSize.height
        try #require(height > 100, "the listening card is taller than the row alone")
        bar.contentSizeDidChange(CGSize(width: CommandBarView.width, height: height))
        await BarWindowFixture.pump()
        defer {
            bar.keepsOpen = { false }
            bar.hide(after: nil)
            bar.close()
        }

        let window = try #require(bar.window)
        #expect(!bar.hasKeyboard && !bar.panelCanBecomeKey, "nothing it listens to is typed at it")
        #expect(bar.isVisible && !bar.panelIgnoresMouseEvents)
        click(at: NSPoint(x: CommandBarView.width - 32, y: height - 32), in: window)
        #expect(clicks == 1)
    }

    @Test("a click that lands while the bar only shows a command (no button there) does nothing")
    func noButtonNoClick() async throws {
        let bar = BarWindowFixture.makeBar()
        var clicks = 0
        bar.model.onMicrophone = { clicks += 1 }
        bar.beginSession()
        bar.show(.thinking(partial: nil))
        await BarWindowFixture.pump()
        defer { bar.hide(after: nil) }

        let window = try #require(bar.window)
        click(at: microphoneCentre(in: window), in: window)
        #expect(clicks == 0)
        #expect(bar.panelIgnoresMouseEvents, "the clicks pass through to the app underneath")
    }
}
