import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import VoxaCore
@testable import VoxaSettings
import VoxaTestSupport

/// These tests open a real window and run the run loop, so AppKit's display cycle (layout, constraint updates) actually
/// happens. That is what once crashed the app on macOS 26 when Settings was opened: `NSHostingController` with
/// `.preferredContentSize` resized the window from Auto Layout inside the layout pass and AppKit threw. If constraint-
/// driven sizing is ever reintroduced, this suite kills the test process instead of passing.
@MainActor
@Suite("SettingsWindowController", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
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
@Suite("SettingsWindowController: tabs", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
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

@MainActor
@Suite("Settings and walkthrough windows: every page", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct EveryPageWindowTests {
    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "com.rohitsainier.voxa.tests.pages.\(UUID().uuidString)")!)
    }

    private func pump(_ seconds: TimeInterval = 0.15) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Services with something in every list, so each page draws real rows rather than its empty state.
    private func fullServices() -> SettingsServices {
        var services = SettingsServices.inert
        services.tools = [
            ToolInfo(name: "open_app", summary: "Opens an app.", risk: .reversible),
            ToolInfo(name: "calendar_list_events", summary: "Lists events.", risk: .readOnly, permissions: [.calendars]),
            ToolInfo(name: "calendar_delete_event", summary: "Deletes an event.", risk: .sensitive, permissions: [.calendars]),
            ToolInfo(name: "run_applescript", summary: "Runs a script.", risk: .sensitive, permissions: [.automation]),
        ]
        services.audit = RecordingAuditLog(
            (0..<6).flatMap { index -> [AuditEntry] in
                let run = UUID()
                return [
                    AuditEntry(runID: run, kind: .command, detail: "command \(index)"),
                    AuditEntry(runID: run, kind: .toolProposed, tool: "open_app"),
                    AuditEntry(runID: run, kind: .reply, outcome: "completed", detail: "Done."),
                ]
            }
        )
        return services
    }

    @Test("opening every tab of Settings in a real window, with rows on each, never crashes and never changes the window's size")
    func everyTab() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let controller = SettingsWindowController(store: makeStore(), services: fullServices())
        controller.show(tab: .general)
        await pump(0.3)
        let size = try #require(controller.windowFrame).size

        for tab in SettingsView.Tab.allCases + SettingsView.Tab.allCases.reversed() {
            controller.show(tab: tab)
            await pump()
            #expect(controller.selectedTab == tab)
            #expect(controller.windowFrame?.size == size, "\(tab) resized the window")
        }
        controller.close()
    }

    @Test("full control going on and off under the Safety and Tools tabs, as the menu-bar item does, never resizes the window")
    func fullControlWhileShowing() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = makeStore()
        let controller = SettingsWindowController(store: store, services: fullServices())
        controller.show(tab: .safety)
        await pump(0.3)
        let size = try #require(controller.windowFrame).size

        for tab in [SettingsView.Tab.safety, .tools, .safety, .tools] {
            controller.show(tab: tab)
            for on in [true, false, true, false] {
                store.current.fullControl = on
                await pump(0.1)
                #expect(controller.selectedTab == tab)
                #expect(controller.windowFrame?.size == size, "\(tab) with full control \(on) resized the window")
            }
        }
        controller.close()
    }

    @Test("the walkthrough opens in a real window, is a fixed size, and can be opened again and closed repeatedly")
    func walkthroughWindow() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let controller = OnboardingWindowController(store: makeStore(), services: fullServices())
        #expect(!controller.isVisible)
        controller.show()
        await pump(0.3)
        #expect(controller.isVisible)
        let frame = try #require(NSApp.windows.first { $0.title == L10n.Onboarding.windowTitle }?.frame)
        #expect(frame.width == OnboardingView.contentSize.width)

        for _ in 0..<6 {
            controller.show()
            await pump(0.05)
            controller.close()
            await pump(0.03)
        }
        #expect(!controller.isVisible)
    }

    @Test("the walkthrough opens by itself the first time only")
    func firstTimeOnly() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = makeStore()
        let controller = OnboardingWindowController(store: store, services: fullServices())

        controller.showIfNeeded()
        await pump(0.2)
        #expect(controller.isVisible, "not finished yet, so it opens")
        controller.close()

        store.current.onboardingCompleted = true
        controller.showIfNeeded()
        await pump(0.2)
        #expect(!controller.isVisible, "finished, so it stays away until asked for")
    }

    @Test("closing the walkthrough any way at all counts as having seen it, so it doesn't come back on every launch")
    func closingCountsAsSeen() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let store = makeStore()
        let controller = OnboardingWindowController(store: store, services: fullServices())
        #expect(!store.current.onboardingCompleted)
        // The window this controller opens, not whichever walkthrough window the process happens to list first.
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show()
        #expect(await waitUntil { controller.isVisible })
        let mine = NSApp.windows.first { $0.title == L10n.Onboarding.windowTitle && !before.contains(ObjectIdentifier($0)) }
        #expect(mine != nil, "the walkthrough opened a window")
        mine?.close()  // the window's own close button, rather than the walkthrough's Done
        #expect(await waitUntil { store.current.onboardingCompleted })
    }

    @Test("each step of the walkthrough lays out at the window's size without trouble")
    func everyStepLaysOut() async {
        _ = NSApplication.shared
        for step in OnboardingModel.Step.allCases {
            let view = OnboardingView(store: makeStore(), services: fullServices(), startingAt: step) {}
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: OnboardingView.contentSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.frame.size == OnboardingView.contentSize, "\(step)")
            await pump(0.05)
        }
    }
}

@MainActor
@Suite("Full control: the question", .serialized, .windowLock, .enabled(if: CGDisplayIsActive(CGMainDisplayID()) != 0))
struct FullControlQuestionTests {
    private struct Host: View {
        @State var asking = true
        var body: some View {
            Text("host")
                .frame(width: 300, height: 200)
                .fullControlQuestion(isPresented: $asking, give: {}, keepAsking: {})
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? [] + view.subviews.flatMap(buttons)
    }

    @Test("Return can't turn full control on: its button is not the default one, and Esc is Keep Asking")
    func returnDoesNotGiveControl() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host())
        window.orderFrontRegardless()
        defer { window.close() }
        try? await Task.sleep(for: .milliseconds(700))

        let sheet = try #require(window.attachedSheet, "the question is showing")
        let found = buttons(in: try #require(sheet.contentView))
        let give = try #require(found.first { $0.title == L10n.FullControl.confirmGive })
        let keep = try #require(found.first { $0.title == L10n.FullControl.confirmKeepAsking })

        #expect(give.keyEquivalent != "\r", "Return must not press Give Full Control")
        #expect(sheet.defaultButtonCell?.title != L10n.FullControl.confirmGive)
        #expect(keep.keyEquivalent == "\u{1B}", "Esc keeps asking")
        window.endSheet(sheet)
    }
}
