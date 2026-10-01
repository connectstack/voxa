import AppKit
import Foundation

/// How Siri is set up on this Mac.
public struct SiriSetup: Sendable, Equatable {
    /// Siri is switched on at all.
    public var isEnabled: Bool
    /// "Hey Siri": Siri listens for its name, so that nothing has to be touched to talk to it.
    public var listensForHeySiri: Bool

    public init(isEnabled: Bool, listensForHeySiri: Bool) {
        self.isEnabled = isEnabled
        self.listensForHeySiri = listensForHeySiri
    }
}

/// Looks at how Siri is set up, and opens the place where that is changed. Voxa talks to Siri only through an App Intent that Siri
/// itself runs (see `SiriCommand`); this is just so that Settings and the menu can say what is missing.
@MainActor
public protocol SiriInspecting: Sendable {
    func setup() -> SiriSetup
    /// Opens Siri's pane in System Settings.
    func openSettings()
}

/// The real thing: Siri's own preferences, which are only ever read, and System Settings.
@MainActor
public struct SystemSiri: SiriInspecting {
    private let siri: UserDefaults?
    private let assistant: UserDefaults?

    public init(
        siri: UserDefaults? = UserDefaults(suiteName: "com.apple.Siri"),
        assistant: UserDefaults? = UserDefaults(suiteName: "com.apple.assistant.support")
    ) {
        self.siri = siri
        self.assistant = assistant
    }

    public func setup() -> SiriSetup {
        SiriSetup(
            // A Mac that says nothing about it is taken to have Siri on: better to say nothing than to nag.
            isEnabled: assistant?.object(forKey: "Assistant Enabled") as? Bool ?? true,
            listensForHeySiri: siri?.bool(forKey: "VoiceTriggerUserEnabled") ?? false
        )
    }

    public func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Nothing behind it: Siri is on and does not listen for its name, and opening its settings does nothing.
public struct InertSiri: Sendable {
    public init() {}
}

// The conformance is declared here, not on the type, so that making one is not itself tied to the main actor: it is a default argument.
extension InertSiri: SiriInspecting {
    public func setup() -> SiriSetup { SiriSetup(isEnabled: true, listensForHeySiri: false) }
    public func openSettings() {}
}
