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
