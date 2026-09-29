import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import EventKit
import Foundation
import Speech
import VoxaCore

/// Checks and requests the system permissions Voxa depends on.
///
/// `@MainActor` because requesting access presents system UI and the results drive SwiftUI. Milestone status:
/// microphone and speech recognition can be requested here; the other kinds report their live status and are
/// wired up for requesting (with the onboarding flow) together with the tools that need them.
@MainActor
public protocol PermissionsProviding: AnyObject {
    /// The current status, without prompting.
    func status(of kind: PermissionKind) -> PermissionStatus
    /// Prompts the user when the status is `.notDetermined`, then returns the resulting status.
    func request(_ kind: PermissionKind) async -> PermissionStatus
    /// Opens the System Settings pane where the user can change `kind`.
    func openSystemSettings(for kind: PermissionKind)
}

extension PermissionsProviding {
    /// Makes sure every kind is granted, asking for the undetermined ones in order.
    ///
    /// - Returns: `nil` when all are granted, otherwise a ready-to-show error for the first one that isn't.
    public func ensureGranted(_ kinds: [PermissionKind]) async -> UserFacingError? {
        for kind in kinds {
            var status = self.status(of: kind)
            if status == .notDetermined {
                status = await request(kind)
            }
            if !status.isGranted {
                return .permissionRequired(kind, status: status)
            }
        }
        return nil
    }
}

/// Deep links into System Settings › Privacy & Security. The legacy `com.apple.preference.security` identifier still
/// routes correctly on macOS 13 through 26.
public enum SystemSettingsPane {
    public static func url(for kind: PermissionKind) -> URL {
        let anchor = switch kind {
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .calendars: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        case .automation: "Privacy_Automation"
        }
        // The literal is constant and well-formed.
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

@MainActor
public final class SystemPermissionsManager: PermissionsProviding {
    private let openURL: @MainActor (URL) -> Void

    /// - Parameter openURL: Injectable so tests never launch System Settings.
    public init(openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    public func status(of kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone:
            PermissionStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            PermissionStatus(SFSpeechRecognizer.authorizationStatus())
        case .accessibility:
            // macOS never reports "not determined" for Accessibility; an untrusted process is simply not listed yet.
            AXIsProcessTrusted() ? .granted : .notDetermined
        case .screenRecording:
            CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .calendars:
            Self.eventKitStatus(for: .event)
        case .reminders:
            Self.eventKitStatus(for: .reminder)
        case .automation:
            // Automation is granted per target app; the per-app check arrives with the tools that use it.
            .notDetermined
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        // Menu-bar apps are not frontmost by default, and a prompt from a background app can appear behind other windows.
        NSApp.activate()
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speechRecognition:
            return await Self.requestSpeechAuthorization()
        case .accessibility, .screenRecording, .calendars, .reminders, .automation:
            Log.permissions.info("no in-app request flow for \(kind.rawValue, privacy: .public) yet")
        }
        return status(of: kind)
    }

    public func openSystemSettings(for kind: PermissionKind) {
        openURL(SystemSettingsPane.url(for: kind))
    }

    // MARK: Helpers

    /// `nonisolated` on purpose: the Speech framework calls back on an arbitrary queue, and a closure formed in a
    /// `@MainActor` context would trap when run there.
    private nonisolated static func requestSpeechAuthorization() async -> PermissionStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: PermissionStatus(status))
            }
        }
    }

    private static func eventKitStatus(for entity: EKEntityType) -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        // Write-only access cannot read events, which the calendar tools need.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
    }
}
