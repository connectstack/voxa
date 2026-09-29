import Foundation
import Observation
import VoxaCore

/// What the Permissions tab and the walkthrough know about the permissions they list, and what each row should offer.
///
/// Statuses are read live and never prompt; asking is always the user pressing a button. macOS sends no notification when a
/// permission changes in System Settings (Accessibility and Screen Recording in particular), so whoever shows this calls
/// `refresh()` on a timer and when the app comes to the front.
@MainActor
@Observable
public final class PermissionsModel {
    /// What a row offers for a permission in its current state.
    public enum Action: Hashable, Sendable {
        /// Nothing the user can do: already allowed, or restricted by policy.
        case none
        /// Ask macOS now; it shows its own prompt.
        case allow
        /// The switch has to be turned on in System Settings.
        case openSystemSettings
    }

    public let kinds: [PermissionKind]
    public private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    /// The permission whose prompt is on screen right now, if any.
    public private(set) var requesting: PermissionKind?

    @ObservationIgnored private let permissions: any PermissionsProviding

    public init(permissions: any PermissionsProviding, kinds: [PermissionKind]) {
        self.permissions = permissions
        self.kinds = kinds
        refresh()
    }

    public func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? permissions.status(of: kind)
    }

    /// Reads every status again. Cheap and prompt-free.
    public func refresh() {
        var fresh: [PermissionKind: PermissionStatus] = [:]
        for kind in kinds { fresh[kind] = permissions.status(of: kind) }
        if fresh != statuses { statuses = fresh }
    }

    /// Whether every listed permission is allowed.
    public var allGranted: Bool {
        kinds.allSatisfy { status(of: $0).isGranted }
    }

    /// Everything a row should offer, in the order to show it. Accessibility and Screen Recording are the awkward ones: asking only
    /// makes macOS show a dialog and list Voxa, and the switch is flipped in System Settings, which is also where to go if the
    /// dialog was dismissed or doesn't appear again. So both buttons are there until it is on.
    public func actions(for kind: PermissionKind) -> [Action] {
        switch status(of: kind) {
        case .granted, .restricted:
            return []
        case .denied:
            return [.openSystemSettings]
        case .notDetermined:
            // Automation is asked per app when a script needs it, so the most Voxa can do ahead of time is point at the pane.
            if kind.isPerApp { return [.openSystemSettings] }
            return kind.isGrantedInSystemSettings ? [.allow, .openSystemSettings] : [.allow]
        }
    }

    /// The first thing a row offers, or `.none`.
    public func action(for kind: PermissionKind) -> Action {
        actions(for: kind).first ?? .none
    }

    /// Asks macOS for `kind`. Accessibility and Screen Recording come back at once with nothing decided, so a later
    /// `refresh()` is what shows the outcome.
    public func request(_ kind: PermissionKind) async {
        guard requesting == nil else { return }
        requesting = kind
        _ = await permissions.request(kind)
        requesting = nil
        refresh()
    }

    public func openSystemSettings(for kind: PermissionKind) {
        permissions.openSystemSettings(for: kind)
    }

    /// Does what the row's button says.
    public func perform(_ action: Action, for kind: PermissionKind) async {
        switch action {
        case .none: break
        case .allow: await request(kind)
        case .openSystemSettings: openSystemSettings(for: kind)
        }
    }
}
