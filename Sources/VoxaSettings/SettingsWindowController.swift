import AppKit
import SwiftUI
import VoxaCore
import VoxaLLM

/// Presents the settings window from a menu-bar app. SwiftUI's `Settings` scene is unreliable for accessory apps
/// (no app menu, no activation), so the window is created and activated explicitly.
@MainActor
public final class SettingsWindowController {
    private let store: SettingsStore
    private let services: ProviderServices
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    public init(store: SettingsStore, services: ProviderServices = .inert) {
        self.store = store
        self.services = services
    }

    /// Opens the window, on `tab` if one is given (otherwise wherever it was last left).
    public func show(tab: SettingsView.Tab? = nil) {
        if let tab { navigation.tab = tab }
        let window = self.window ?? makeWindow()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The window's frame, for tests and diagnostics.
    var windowFrame: NSRect? { window?.frame }

    /// The tab that is showing (or will show when the window opens), for tests and diagnostics.
    public var selectedTab: SettingsView.Tab { navigation.tab }

    /// Closes the window if it is open.
    public func close() {
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        // The content has a fixed size, and the window is created at exactly that size: nothing asks Auto Layout to
        // resize it. (Constraint-driven window sizing, e.g. `NSHostingController` with `.preferredContentSize`, crashes
        // AppKit's layout pass on macOS 26; see HUDView.init.)
        let host = NSHostingView(rootView: SettingsView(store: store, services: services, navigation: navigation))
        host.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.title = L10n.Settings.windowTitle
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}
