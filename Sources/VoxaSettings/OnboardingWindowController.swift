import AppKit
import SwiftUI
import VoxaCore

/// Presents the first-run walkthrough, in a fixed-size window of its own, the same way and for the same reasons as
/// `SettingsWindowController`: the window is created at exactly its content's size and nothing asks Auto Layout to resize it.
///
/// However it is closed (its button, or the window's own close button), it counts as seen: a walkthrough that came back on every
/// launch until it was finished would be a nag, and it can always be reopened from Settings.
@MainActor
public final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let store: SettingsStore
    private let services: SettingsServices
    private var window: NSWindow?

    public init(store: SettingsStore, services: SettingsServices = .inert) {
        self.store = store
        self.services = services
        super.init()
    }

    /// Whether the window is on screen.
    public var isVisible: Bool { window?.isVisible == true }

    /// Opens the walkthrough at its first step (a fresh one each time it is opened), or at a later one, to look at that page.
    public func show(step: Int = 0) {
        window?.close()
        let window = makeWindow(startingAt: OnboardingModel.Step(rawValue: step) ?? .welcome)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window if it is open.
    public func close() {
        window?.close()
    }

    /// Opens the walkthrough if it has never been finished.
    public func showIfNeeded() {
        guard !store.current.onboardingCompleted else { return }
        show()
    }

    private func makeWindow(startingAt step: OnboardingModel.Step) -> NSWindow {
        let view = OnboardingView(store: store, services: services, startingAt: step) { [weak self] in self?.close() }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingView.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.title = L10n.Onboarding.windowTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    public nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { store.current.onboardingCompleted = true }
    }
}
