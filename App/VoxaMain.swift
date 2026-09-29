import SwiftUI
import VoxaApp

/// The app's entry point. Everything else lives in the `VoxaApp` package module; this file exists because an Xcode
/// application target needs an `@main` type to carry the Info.plist, entitlements, signing and icon.
@main
struct VoxaMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarScene(environment: delegate.environment)
    }
}
