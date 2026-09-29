import AVFoundation
import Foundation
import Speech

/// The system permissions Voxa can need. Which ones a command requires depends on the tools it uses.
public enum PermissionKind: String, CaseIterable, Sendable, Codable, Identifiable {
    case microphone
    case speechRecognition
    case accessibility
    case screenRecording
    case calendars
    case reminders
    /// Apple Events automation. Granted per target app, so the generic status is only a summary.
    case automation

    public var id: String { rawValue }

    /// Whether the grant is per target app (Automation): macOS asks the first time a script controls each app, so it can't be
    /// asked for ahead of time, and a tool that needs it must not be held up waiting for one general answer.
    public var isPerApp: Bool { self == .automation }

    /// Whether the switch is turned on in System Settings rather than answered in a prompt. The app can ask, which shows a
    /// dialog and adds it to the list there, but the user has to go and flip it: so a button that opens that pane is always needed.
    public var isGrantedInSystemSettings: Bool { self == .accessibility || self == .screenRecording }

    /// The SF Symbol shown next to it in Settings and the walkthrough.
    public var symbolName: String {
        switch self {
        case .microphone: "mic.fill"
        case .speechRecognition: "waveform"
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .automation: "gearshape.2.fill"
        }
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case notDetermined
    case denied
    /// Blocked by policy (parental controls, MDM); the user cannot change it in System Settings.
    case restricted

    public var isGranted: Bool { self == .granted }
}

extension PermissionStatus {
    /// Microphone (and camera) authorization as reported by AVFoundation.
    public init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }

    /// Speech recognition authorization as reported by the Speech framework.
    public init(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        @unknown default: self = .denied
        }
    }
}
