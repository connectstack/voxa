import AppKit
import CoreGraphics
import Foundation
import Testing
import VoxaCore
@testable import VoxaSettings

/// These tests open a real window and run the run loop, so AppKit's display cycle (layout, constraint updates) actually
/// happens. That is what once crashed the app on macOS 26 when Settings was opened: `NSHostingController` with
/// `.preferredContentSize` resized the window from Auto Layout inside the layout pass and AppKit threw. If constraint-
/// driven sizing is ever reintroduced, this suite kills the test process instead of passing.
@MainActor
@Suite("SettingsWindowController", .serialized, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct SettingsWindowTests {
    private func makeController() -> SettingsWindowController {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)   // like the real app: windows work, no Dock icon
        let suite = "com.rohitsainier.voxa.tests.window.\(UUID().uuidString)"
        return SettingsWindowController(store: SettingsStore(defaults: UserDefaults(suiteName: suite)!))
    }

    /// Waits while yielding the main actor, so the main run loop (display cycle, animations) and any main-actor tasks
    /// the code under test scheduled can actually run. A synchronous nested run loop would block those tasks.
    private func pump(_ seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test("opening Settings sizes the window to its content and centers it, without crashing")
    func opens() async throws {
        let controller = makeController()
        controller.show()
        await pump()
        defer { controller.close() }

        let frame = try #require(controller.windowFrame)
        #expect(frame.width == SettingsView.contentSize.width, "got \(frame.width)")
        #expect(frame.height >= SettingsView.contentSize.height, "the window includes a title bar on top of the content, got \(frame.height)")
        #expect(frame.height < SettingsView.contentSize.height + 80)

        let screen = try #require(NSScreen.main).visibleFrame
        #expect(abs(frame.midX - screen.midX) < 2, "not centered horizontally: window midX \(frame.midX), screen midX \(screen.midX)")
    }

    @Test("opening and closing repeatedly, with layout running in between, never crashes")
    func openCloseStress() async {
        let controller = makeController()
        for _ in 0..<12 {
            controller.show()
            await pump(0.05)
            controller.close()
            await pump(0.03)
        }
        controller.show()
        await pump(0.2)
        #expect(controller.windowFrame != nil)
        controller.close()
    }

    @Test("showing an already-open window keeps its size")
    func reopen() async throws {
        let controller = makeController()
        controller.show()
        await pump(0.2)
        let first = try #require(controller.windowFrame)
        controller.show()
        await pump(0.2)
        #expect(controller.windowFrame?.size == first.size)
        controller.close()
    }
}

@MainActor
@Suite("SettingsWindowController: tabs", .serialized, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct SettingsWindowTabTests {
    @Test("switching provider with the Model tab open, back and forth, never crashes and keeps the window's size")
    func switchingProviders() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "com.rohitsainier.voxa.tests.window.\(UUID().uuidString)"
        let store = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        let controller = SettingsWindowController(store: store)
        controller.show(tab: .model)
        try? await Task.sleep(for: .seconds(0.3))
        let size = try #require(controller.windowFrame).size

        for _ in 0..<3 {
            for provider in ModelProvider.allCases + [.anthropic] {
                store.current.provider = provider
                try? await Task.sleep(for: .seconds(0.12))
            }
        }
        // Address changes while the Ollama page is showing (each one restarts the server check).
        store.current.provider = .ollama
        for address in ["http://localhost:1", "not an address", "http://127.0.0.1:2", AppSettings.defaultOllamaBaseURL] {
            store.current.ollamaBaseURL = address
            try? await Task.sleep(for: .seconds(0.1))
        }
        try? await Task.sleep(for: .seconds(0.7))

        #expect(controller.windowFrame?.size == size, "the window is a fixed size whatever the page holds")
        controller.close()
    }

    private func makeController() -> SettingsWindowController {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "com.rohitsainier.voxa.tests.window.\(UUID().uuidString)"
        return SettingsWindowController(store: SettingsStore(defaults: UserDefaults(suiteName: suite)!))
    }

    @Test("an error's button can open Settings on the tab where the problem is put right, and the choice sticks")
    func opensOnTab() async {
        let controller = makeController()
        #expect(controller.selectedTab == .general)

        controller.show(tab: .model)
        #expect(controller.selectedTab == .model)
        try? await Task.sleep(for: .seconds(0.2))

        controller.show()
        #expect(controller.selectedTab == .model, "opening without a tab leaves it where it was")

        controller.show(tab: .safety)
        #expect(controller.selectedTab == .safety)
        controller.close()
    }
}
