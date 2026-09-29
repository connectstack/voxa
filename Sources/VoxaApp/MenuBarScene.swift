import AppKit
import SwiftUI
import VoxaCore

/// The app's only scene: the menu-bar item. Its icon reflects the coarse app state, and its menu shows what the app is
/// doing plus Settings and Quit.
public struct MenuBarScene: Scene {
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContent(environment: environment)
        } label: {
            Image(systemName: environment.session.status.symbolName)
                .accessibilityLabel(L10n.Menu.accessibilityLabel)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarContent: View {
    let environment: AppEnvironment

    var body: some View {
        Text(statusText)
        Divider()
        #if DEBUG
        Menu("Debug: preview HUD") {
            ForEach(DebugHUDState.allCases, id: \.self) { state in
                Button(state.title) { environment.showDebugHUD(state) }
            }
        }
        Divider()
        #endif
        Button(L10n.Menu.settings) {
            // Open the window on the next turn, once the menu has finished closing, instead of from inside the
            // menu's event-tracking loop.
            Task { @MainActor in environment.settingsWindow.show() }
        }
        .keyboardShortcut(",")
        Divider()
        Button(L10n.Menu.quit) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusText: String {
        switch environment.session.status {
        case .idle:
            environment.hotkeys.pushToTalkDescription.map(L10n.Menu.ready) ?? L10n.Menu.readyNoShortcut
        case .listening: L10n.Menu.listening
        case .thinking: L10n.Menu.thinking
        case .acting: L10n.Menu.acting
        case .confirming: L10n.Menu.confirming
        case .error: environment.session.lastError?.title ?? L10n.Menu.problem
        }
    }
}

extension AppStatus {
    /// SF Symbol for the menu-bar icon. Template rendering keeps it legible in light and dark menu bars.
    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .listening: "mic.fill"
        case .thinking: "waveform"
        case .acting: "bolt.fill"
        case .confirming: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}
