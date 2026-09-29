import AppKit

/// Hosts the app-level lifecycle that SwiftUI's `App` protocol doesn't expose. Created by the `@main` app struct through
/// `@NSApplicationDelegateAdaptor`, so `environment` exists before the first scene is built.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let environment = AppEnvironment()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // The Info.plist already sets LSUIElement; this keeps `swift run` and previews menu-bar-only as well.
        NSApp.setActivationPolicy(.accessory)
        environment.start()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
