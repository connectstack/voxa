import Foundation

/// What the user can do about an error, rendered as a button in the HUD.
public enum RecoveryAction: Sendable, Equatable {
    case openSystemSettings(PermissionKind)
    case openAppSettings
    /// Voxa's settings, on the Model tab: where a missing key, a rejected key or a wrong model is put right.
    case openModelSettings
    /// Launch the Ollama app, which starts the local model server.
    case openOllama
    case retry

    public var title: String {
        switch self {
        case .openSystemSettings: L10n.Recovery.openSystemSettings
        case .openAppSettings, .openModelSettings: L10n.Recovery.openAppSettings
        case .openOllama: L10n.Recovery.openOllama
        case .retry: L10n.Recovery.retry
        }
    }
}

/// A failure described for a person, not for a log. Every error that can reach the user is converted to this
/// type so nothing fails silently and nothing surfaces as "The operation couldn't be completed. (com.apple… error 1110)".
public struct UserFacingError: Error, Sendable, Equatable {
    public var title: String
    public var detail: String
    public var recovery: RecoveryAction?

    public init(title: String, detail: String, recovery: RecoveryAction? = nil) {
        self.title = title
        self.detail = detail
        self.recovery = recovery
    }
}

extension UserFacingError: LocalizedError {
    public var errorDescription: String? { title }
    public var failureReason: String? { detail }
}

/// Adopted by module-specific error enums so the coordinator can present them uniformly.
public protocol UserFacingConvertible: Error {
    var userFacing: UserFacingError { get }
}

extension UserFacingError {
    /// Converts any error into something safe and readable. Known types keep their own wording; anything else
    /// gets a generic title with the system's description as detail (the full error is logged by the caller).
    public static func describing(_ error: any Error) -> UserFacingError {
        if let userFacing = error as? UserFacingError { return userFacing }
        if let convertible = error as? any UserFacingConvertible { return convertible.userFacing }
        return UserFacingError(
            title: L10n.Errors.genericTitle,
            detail: (error as NSError).localizedDescription,
            recovery: .retry
        )
    }

    /// The standard "a permission is missing" message, with a button that opens the right System Settings pane.
    public static func permissionRequired(_ kind: PermissionKind, status: PermissionStatus) -> UserFacingError {
        let text = L10n.Permissions.text(for: kind, status: status)
        return UserFacingError(
            title: text.title,
            detail: text.detail,
            recovery: status == .restricted ? nil : .openSystemSettings(kind)
        )
    }
}
